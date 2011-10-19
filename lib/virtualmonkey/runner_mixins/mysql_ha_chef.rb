module VirtualMonkey
  module Mixin
    module ChefMysqlHA
      include VirtualMonkey::Mixin::DeploymentBase
      include VirtualMonkey::Mixin::EBS
      attr_accessor :scripts_to_run
      attr_accessor :db_ebs_prefix

      def mysql_servers
        res = []
        @servers.each do |server|
          st = ServerTemplate.find(resource_id(server.server_template_href))
          if st.nickname =~ /Database Manager/
            res << server
          end
        end
        raise "FATAL: No Database Manager servers found" unless res.length > 0
        res
      end

      # lookup all the RightScripts that we will want to run
      def mysql_lookup_scripts
       scripts = [
                   [ 'setup_block_device',           'db::setup_block_device' ],
                   [ 'do_backup',                    'db::do_backup' ],
                   [ 'do_restore',                   'db::do_restore' ],
                   [ 'do_force_reset',               'db::do_force_reset' ],
                   [ 'setup_rule',                   'sys_firewall::setup_rule' ],
                   [ 'do_list_rules',                'sys_firewall::do_list_rules' ],
                   [ 'do_reconverge_list_enable',    'sys::do_reconverge_list_enable' ],
                   [ 'do_reconverge_list_disable',   'sys::do_reconverge_list_disable' ],
                   [ 'do_init_slave',                'db::do_init_slave'],
                   [ 'do_promote_to_master',         'db::do_promote_to_master'],
                   [ 'setup_master_dns',             'db::setup_master_dns'],
                   [ 'do_restore_and_become_master', 'db::do_restore_and_become_master' ],
                   [ 'do_tag_as_master',             'db::do_tag_as_master' ],
                   [ 'setup_replication_privileges', 'db::setup_replication_privileges' ],
                   [ 'setup_master_backup',          'db::do_backup_schedule_enable'    ],
                   [ 'setup_slave_backup',           'db::do_backup_schedule_enable'    ],
                   ['disable_backups',              'db::do_backup_schedule_disable'   ],
                   ['do_secondary_backup',              'db::do_secondary_backup'    ],
                   ['do_secondary_restore',            'db::do_secondary_restore'    ],
                   [ 'setup_privileges_admin',         'db::setup_privileges_admin'  ]
                 ]
        raise "FATAL: Need 1 MySQL servers in the deployment" unless servers.size >= 1

        st = ServerTemplate.find(resource_id(mysql_servers.first.server_template_href))
        load_script_table(st,scripts,st)
      end

      # Find all snapshots associated with this server
      def find_snapshots(server)
        s = server
        if (s.current_instance_href)
          s.reload_as_current
          s.settings
          s.reload_as_next
        end

        s.settings

        unless @lineage
          kind_params = s.parameters
          @lineage = kind_params['db/backup/lineage'].gsub(/text:/, "")
        end
        if s.cloud_id.to_i < 10
          snapshots = Ec2EbsSnapshot.find_by_tags("rs_backup:lineage=#{@lineage}")
        elsif s.cloud_id.to_i == 232
          snapshots = [] # Ignore Rackspace, there are no snapshots
        else
          snapshots = McVolumeSnapshot.find_by_tags("rs_backup:lineage=#{@lineage}").select { |vs| vs.cloud.split(/\//).last.to_i == s.cloud_id.to_i }
        end
        snapshots
      end

      def find_snapshot_timestamp(server, provider = :volume)
        case provider
        when :volume
          if server.cloud_id.to_i != 232
            last_snap = find_snapshots.last
            last_snap.tags(true).detect { |t| t =~ /timestamp=(\d+)$/ }
            timestamp = $1
          else #Rackspace uses cloudfiles object store
            cloud_files = Fog::Storage.new(:provider => 'Rackspace')
            if dir = cloud_files.directories.detect { |d| d.key == @container }
              dir.files.first.key =~ /-([0-9]+\/[0-9]+)/
              timestamp = $1
            end
          end
        when "S3"
          s3 = Fog::Storage.new(:provider => 'AWS')
          if dir = s3.directories.detect { |d| d.key == @secondary_container }
            dir.files.first.key =~ /-([0-9]+\/[0-9]+)/
            timestamp = $1
          end
        when "CloudFiles"
          cloud_files = Fog::Storage.new(:provider => 'Rackspace')
          if dir = cloud_files.directories.detect { |d| d.key == @secondary_container }
            dir.files.first.key =~ /-([0-9]+\/[0-9]+)/
            timestamp = $1
          end
        else
          raise "FATAL: Provider #{provider.to_s} not supported."
        end
        return timestamp
      end

      def cleanup_snapshots
         mysql_servers.each do |server|
           find_snapshots(server).each do |snap|
             snap.destroy
          end
        end
        # TODO cleanup secondary_container
      end

      def cleanup_volumes
        mysql_servers.each do |server|
          unless ["stopped", "pending", "inactive", "decommissioning", "terminating"].include?(server.state)
            run_script("do_force_reset", server)
          end
        end
      end

      def import_unified_app_sqldump
        load_script('import_dump', RightScript.new('href' => '/api/acct/2901/right_scripts/187123'))
        raise "Did not find script: import_dump" unless script_to_run?('import_dump')
        run_script_on_set('import_dump', mysql_servers, true, { 'DBAPPLICATION_PASSWORD' => 'cred:DBAPPLICATION_PASSWORD', 'DBAPPLICATION_USER' => 'cred:DBAPPLICATION_USER' })
      end

      # sets the lineage for the deployment
      # * kind<~String> can be "chef" or nil
      def set_variation_lineage()
        @lineage = "testlineage#{resource_id(@deployment)}"
        puts "Set variation LINEAGE: #{@lineage}"
        @deployment.set_input('db/backup/lineage', "text:#{@lineage}")
        @servers.each do |server|
          server.set_inputs({"db/backup/lineage" => "text:#{@lineage}"})
        end
      end

      def set_variation_container
        @container = "testlineage#{resource_id(@deployment)}"
        puts "Set variation CONTAINER: #{@container}"
        @deployment.set_input("block_device/storage_container", "text:#{@container}")
        @servers.each do |server|
          server.set_inputs({"block_device/storage_container" => "text:#{@container}"})
        end
      end

      # sets the storage provider for the server
      # * kind<~String> can be "chef" or nil
      def set_variation_storage_account_provider(provider)
        @deployment.set_input("db_mysql/dump/storage_account_provider", "text:#{provider}")
        @servers.each do |server|
          server.set_inputs({"db_mysql/dump/storage_account_provider" => "text:#{provider}"})
        end
        # Set the username and auth inputs for the account provider

        case provider
        when "ec2"
          @servers.each do |server|
            server.set_inputs({"block_device/storage_account_id" => "cred:AWS_ACCESS_KEY_ID"})
            server.set_inputs({"block_device/storage_account_secret" => "cred:AWS_SECRET_ACCESS_KEY"})
          end
        when "rackspace"
          @servers.each do |server|
            server.set_inputs({"block_device/storage_account_id" => "cred:RACKSPACE_USERNAME"})
            server.set_inputs({"block_device/storage_account_secret" => "cred:RACKSPACE_AUTH_KEY"})
          end
        else
          raise "FATAL: Provider #{provider.to_s} not supported."
        end
      end

      def test_primary_backup
        run_script("setup_block_device", s_one)
        probe(s_one, "touch /mnt/storage/monkey_was_here")
        run_script("do_backup", s_one)
        wait_for_snapshots
        run_script("do_force_reset", s_one)
        run_script("do_restore", s_one)
        probe(s_one, "ls /mnt/storage") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
        run_script("do_force_reset", s_one)
        run_script("do_restore", s_one, {"db/backup/timestamp_override" =>
                                         "text:#{find_snapshot_timestamp(s_one)}" })
        probe(s_one, "ls /mnt/storage") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
      end

      def set_secondary_backup_inputs(location="S3")
        @secondary_container = "testsecondary#{resource_id(@deployment)}"
        puts "Set secondary backup CONTAINER: #{@secondary_container}"
        @deployment.set_input("db/backup/secondary_container", "text:#{@secondary_container}")
        @servers.each do |server|
          server.set_inputs({"db/backup/secondary_container" => "text:#{@secondary_container}"})
        end
        location ||= "CloudFiles"
        puts "Set secondary backup LOCATION: #{location}"
        @deployment.set_input( "db/backup/secondary_location", "text:#{location}")
        @servers.each do |server|
          server.set_inputs({"db/backup/secondary_location" => "text:#{location}"})
        end
      end

      def test_secondary_backup(location="S3")
        cid = VirtualMonkey::Toolbox::determine_cloud_id(s_one)
        if cid == 232 && location == "CloudFiles"
          puts "Skipping secondary backup to cloudfiles on Rax -- this is already used for primary backup."
        else
          set_secondary_backup_inputs(location)
          run_script("setup_block_device", s_one)
          probe(s_one, "touch /mnt/storage/monkey_was_here")
          run_script("do_secondary_backup", s_one)
          wait_for_snapshots
          run_script("do_force_reset", s_one)
          run_script("do_secondary_restore", s_one)
          probe(s_one, "ls /mnt/storage") do |result, status|
            raise "FATAL: no files found in the backup" if result == nil || result.empty?
            true
          end
          run_script("do_force_reset", s_one)
          run_script("do_secondary_restore", s_one, { "db/backup/timestamp_override" =>
                                                      "text:#{find_snapshot_timestamp(s_one,location)}" })
          probe(s_one, "ls /mnt/storage") do |result, status|
            raise "FATAL: no files found in the backup" if result == nil || result.empty?
            true
          end
        end
      end

      def run_chef_checks
        # check that mysql tmpdir is custom setup on all servers
          query = "show variables like 'tmpdir'"
          query_command = "echo -e \"#{query}\"| mysql"
          probe(@servers, query_command) { |result,st| result.include?("/mnt/mysqltmp") }

          # check that mysql cron script exits success
          @servers.each do |server|
            chk1 = probe(server, "/usr/local/bin/mysql-binary-backup.rb --if-master --max-snapshots 10 -D 4 -W 1 -M 1 -Y 1")

            chk2 = probe(server, "/usr/local/bin/mysql-binary-backup.rb --if-slave --max-snapshots 10 -D 4 -W 1 -M 1 -Y 1")

            raise "CRON BACKUPS FAILED TO EXEC, Aborting" unless (chk1 || chk2)

            # check that logrotate has mysqlslow in it
            probe(@servers, "logrotate --force -v /etc/logrotate.d/mysql-server") { |out,st| out =~ /mysqlslow/ and st == 0 }
          end
     end

      def enable_db_reconverge
        run_script_on_set('do_reconverge_list_enable', mysql_servers)
      end

      def disable_db_reconverge
        run_script_on_set('do_reconverge_list_disable', mysql_servers)
      end

      # Runs a mysql query on specified server.
      # * query<~String> a SQL query string to execute
      # * server<~Server> the server to run the query on
      def run_query(query, server, &block)
        query_command = "echo -e \"#{query}\"| mysql"
        probe(server, query_command, &block)
      end

      # Use the termination script to stop all the servers (this cleans up the volumes)
      def stop_all(wait=true)
        @servers.each { |s| s.stop }

       wait_for_all("stopped") if wait
        # unset dns in our local cached copy..
        @servers.each { |s| s.params['dns-name'] = nil }
      end

      # uses SharedDns to find an available set of DNS records and sets them on the deployment
      def setup_dns(domain)
        # TODO should we just use the ID instead of the full href?
        owner=@deployment.href
        @dns = SharedDns.new(domain)
        raise "Unable to reserve DNS" unless @dns.reserve_dns(owner)
        @dns.set_dns_inputs(@deployment)

      end

      def setup_all_server_block_devices(servers)
        puts "SETUP_BLOCK_DEVICE"
        servers.each { |s| run_script("setup_block_device", s) }
      end

      def do_backup(server)
        puts "BACKUP"
        delete_backup_file(server)
        run_script("do_backup", server)
        wait_for_snapshots(server)
      end

      def do_restore
        puts "RESTORE"
        run_script("do_restore", s_one)
      end

      # releases records back into the shared DNS pool
      def release_dns
        @dns.release_dns
      end

      def release_container
        set_variation_container
        ary = []
        raise "FATAL: could not cleanup because @container was '#{@container}'" unless @container
        s3 = Fog::Storage.new(:provider => 'AWS')
        ary << s3.directories.all.select {|d| d.key =~ /^#{@container}/}
        if Fog.credentials[:rackspace_username] and Fog.credentials[:rackspace_api_key]
          rax = Fog::Storage.new(:provider => 'Rackspace')
          ary << rax.directories.all.select {|d| d.key =~ /^#{@container}/}
        else
          puts "No Rackspace Credentials!"
        end
        ary.each do |con|
          con.each do |dir|
            dir.files.each do |file|
              file.destroy
            end
            dir.destroy
          end
        end
      end

      def make_master(server)
          run_script('do_tag_as_master', server)
      end

      # create master slave setup
      # verify master and reboot each server in the deployment
      def run_HA_reboot_operations

         obj_behavior(s_two, :reboot, true)
         obj_behavior(s_two, :wait_for_state, "operational")

         obj_behavior(s_one, :reboot, true)
         obj_behavior(s_one, :wait_for_state, "operational")

        wait_for_all("operational")
        run_HA_reboot_checks
      end

      # verify master is still master after the reboot
      # check if reboot delete any tables on each server
      # verify if the master slave setup is present by creating and checking for replication table
      def run_HA_reboot_checks
        # s_one is slave
        # s_two is master
        #s_ three is unit

        verify_master(s_two)

        check_table_bananas(s_two)
        check_table_bananas(s_one)

        # verify master slave setup is still present wiht replication
        create_table_replication(s_two ,"moo")
        check_table_replication(s_one, "moo")
      end

  #    def run_restore_with_timestamp_override
  #      obj_behavior(s_one, :relaunch)
  #      s_one.dns_name = nil
  #      obj_behavior(s_one, :wait_for_operational_with_dns)
  #     run_script('restore', s_one, { "OPT_DB_RESTORE_TIMESTAMP_OVERRIDE" => "text:#{find_snapshot_timestamp}" })
  #    end

  # Check for specific MySQL data.
      def check_mysql_monitoring
        mysql_plugins = [
                         # {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-delete"},
                          {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-create_db"},
                          {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-create_table"},
                          {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-insert"}
                         # {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-show_databases"}
                        ]
        @servers.each do |server|
          transaction {
            #mysql commands to generate data for collectd to return
            50.times do |ii|
              query = <<EOS
              show databases;
              create database test#{ii};
              use test#{ii};
              create table test#{ii}(test text);
              show tables;
              insert into test#{ii} values ('1');
              update test#{ii} set test='2';
              select * from test#{ii};
              delete from test#{ii};
              show variables;
              show status;
              grant select on test.* to root;
              alter table test#{ii} rename to test2#{ii};
EOS
              run_query(query, server)
            end
            mysql_plugins.each do |plugin|
              monitor = server.get_sketchy_data({ 'start' => -60,
                                                  'end' => -20,
                                                  'plugin_name' => plugin['plugin_name'],
                                                  'plugin_type' => plugin['plugin_type']})
              value = monitor['data']['value']
              raise "No #{plugin['plugin_name']}-#{plugin['plugin_type']} data" unless value.length > 0
              # Need to check for that there is at least one non 0 value returned.
              for nn in 0...value.length
                if value[nn] > 0
                  break

                end
              end
              raise "No #{plugin['plugin_name']}-#{plugin['plugin_type']} time" unless nn < value.length
              puts "Monitoring is OK for #{plugin['plugin_name']}-#{plugin['plugin_type']}"
            end
          }
        end
      end

      def set_variation_dnschoice(dns_choice)
        @deployment.set_input("sys_dns/choice", "#{dns_choice}")
        @servers.each do |server|
           server.set_inputs({"sys_dns/choice" => "#{dns_choice}"})
        end

      end

      def set_variation_http_only
        @deployment.set_input("web_apache/ssl_enable", "text:false")
      end

      def config_master_from_scratch(server)
       create_stripe(server)
        probe(server, "service mysqld start") # TODO Check that it started?
        #TODO the service name depends on the OS
        #      server.spot_check_command("service mysql start")
       run_query("create database mynewtest", server)
       set_master_dns(server)
        # This sleep is to wait for DNS to settle - must sleep
        sleep 120
        run_script("do_backup", server)
      end

      def slave_init_server(server)
        run_script("do_init_slave", server)
      end

      def restore_server(server)
        run_script("do_restore ", server)
      end

      def set_master_dns(server)
        run_script('setup_master_dns', server)
      end

       ## checks if the server is in fact a master

       #checks if the server is in fact a master and if the dns is pointing to the master server
      def verify_master(assumed_master_server)

        # sometimes the tags take a while to appear so wait a bit
        sleep 60
        assumed_master_server.reload
        current_max_master_timestamp = -5
        current_max_master_server = nil

        servers.each{ |potential_new_master|
          potential_new_master.settings
          potential_new_master.reload

          master_tags = potential_new_master.get_tags_by_namespace("rs_dbrepl")
          master_tags = master_tags["current_instance"] unless master_tags.nil?
          master_tags = master_tags["master_active"] unless master_tags.nil?

          if(master_tags != nil)
            potential_time_stamp = master_tags.to_i # convert to integer
            if(potential_time_stamp > current_max_master_timestamp)
              current_max_master_timestamp = potential_time_stamp
              current_max_master_server    = potential_new_master
            end
          end
        }
        raise "Theere is no master" unless current_max_master_server.is_a?ServerInterface
        raise "The actual master is #{current_max_master_server.nickname}" unless (assumed_master_server == current_max_master_server)

        # the dns can take 60 seconds to settle in so wait 60 seconds
        sleep 60

        #TODO this errors - not sure why - know it works so skipping it
        db_fqdn = get_input_from_server(assumed_master_server)["db/fqdn"].to_s.split("text:")[1].delete("*")
        dns_ip = `dig +short "#{ db_fqdn}"`

        #raise "DNS ip #{dns_ip.to_s} does not match private ip #{assumed_master_server.private_ip.to_s}" unless (dns_ip.to_s.strip == assumed_master_server.private_ip.to_s)

      end

       def get_master_tags(value)
        timeout= 60
        step=10
        while timeout > 0
          puts "Getting master Active tag"
            print "value\n"+ value.to_s + "\n"
            if value.to_s.match(/master_active/)
              potential_time_stamp = value.to_s.split("=")[1]
              if(Integer(potential_time_stamp) > current_max_master_timestamp)
              current_max_master_timestamp = Integer(potential_time_stamp)
              current_max_master_server    = potential_new_master
              end
           end
           break unless status.include?("pending")
           sleep step
           timeout -= step
        end

       end


      # creates a MySQL enabled EBS stripe on the server
      # * server<~Server> the server to create stripe on
      def create_stripe(server)
        options = { "block_device/volume_size" => "text:1",
                    "db/application/user" => "text:someuser",
                    "block_device/aws_access_key_id" => "ignore:$ignore",
                    "block_device/aws_secret_access_key" => "ignore:$ignore",
                    "db/application/password" => "text:somepass",
                    "block_device/volume_size" => "text:1",
                    "db/backup/lineage" => "text:#{@lineage}" }
        run_script('setup_block_device', server, options)
      end
      def remove_master_tags
        servers.each { |server|
          server.settings
          server.reload
          server.reload
          # clear out any tags that are of type rs_dprepl
          server.clear_tags("rs_dbrepl") # clear out any tags that are of type rs_dprepl
         }
      end

      def create_monkey_table(server)
        run_query("DROP DATABASE IF EXISTS bananas", server)
        run_query("create database bananas", server)
        run_query("use bananas; create table bunches (tree text)", server)
        run_query("use bananas; insert into bunches values ('yellow')", server)
      end

      def check_table_bananas(server)
        run_query("use bananas; select * from bunches;", server){|returned_from_query, returned|
          raise "The bananas table is corrupted" unless returned_from_query.to_s.match(/yellow/) # raise error if the regex does not match
          true
        }
      end

      def create_table_replication(server, database_name)
        run_query("create database #{database_name}", server)
        run_query("use #{database_name}; create table replication (NBA text)", server)
        run_query("use #{database_name}; insert into replication values ('kobe bryant')", server)
      end

      def check_table_replication(server, database_name)
        run_query("use #{database_name}; select * from replication;", server){|returned_from_query, returned|
          raise "The #{database_name} replication database is corrupted" unless returned_from_query.to_s.match(/kobe bryant/) # raise error if the regex does not match
          true
        }
      end

     def write_to_slave(string_to_write_to_slave, slave_server)
      probe(slave_server, "echo #{string_to_write_to_slave} > /mnt/storage/slave.txt")
     end

     def check_slave_backup(server, string_written_to_slave)
       probe(server, "cat /mnt/storage/slave.txt"){|result, status|
         raise "Slave backup failed!!" unless result.include?(string_written_to_slave.to_s)
         true
       }

     end

      # disables backups on all servers
      def disable_all_backups
        servers.each{|server|
        run_script('disable_backups',server)
        }
      end

      def do_force_reset(server)
        run_script("do_force_reset", server)
      end

      def do_restore_and_become_master(server)
        delete_backup_file(server)
        run_script("do_restore_and_become_master",server)
        wait_for_snapshots(server)
        run_script('disable_backups',server)
      end

      def do_init_slave(server)
        delete_backup_file(server)
        run_script("do_init_slave", server)
        wait_for_snapshots(server)
        run_script('disable_backups',server)
      end

      def do_promote_to_master(server)
       delete_backup_file(server)
       run_script("do_promote_to_master",server)
       wait_for_snapshots(server)
       run_script('disable_backups',server)
      end

      def sequential_test
        create_table_replication(s_one ,"foo")
        do_init_slave(s_two)

        # check if the banana table is there
        # check for foo database
        check_table_bananas(s_two)
        check_table_replication(s_two, "foo")

        #      **** VERIFY PROMOTE ****

        do_promote_to_master(s_two)
        verify_master(s_two)
        create_table_replication(s_two ,"bar")
        check_table_replication(s_one, "bar")
        
        #   **** Verify Reboot **** 
        run_HA_reboot_operations
      end

      def test_secondary_backup_ha(location="S3")
        cid = VirtualMonkey::Toolbox::determine_cloud_id(s_one)
        if cid == 232 && location == "CloudFiles"
          puts "Skipping secondary backup to cloudfiles on Rax -- this is already used for primary backup."
        else
          set_secondary_backup_inputs(location)
          create_table_replication(s_one ,"secondary")
          run_script("do_secondary_backup", s_one)
          wait_for_snapshots(s_one)

          run_script("do_secondary_restore", s_two)
          check_table_replication(s_two ,"secondary")

        end
      end

      # tests restore and become master
      # verifies master and slave setup with replication checks
      def restore_and_become_master
        run_script("do_force_reset", s_one)

        # s_one is un-init

        do_restore_and_become_master(s_two)
        verify_master(s_two)
        do_init_slave(s_one)

        # verify master slave setup by a replication test
        create_table_replication(s_two ,"real_master")
        check_table_replication(s_one, "real_master")

        check_table_bananas(s_one)
        check_table_bananas(s_two)
      end

      # creates master and slave from slave backup
      def create_master_from_slave_backup

        verify_master(s_one)
        do_init_slave(s_two)

        # write to slave file system so later we can verify if the backup came from a slave 
        write_to_slave("monkey_slave",s_two) 
        do_backup(s_two)
        run_script("do_force_reset", s_one)
        run_script("do_force_reset", s_two)

        do_restore_and_become_master(s_two)
        check_table_bananas(s_two)
        check_slave_backup(s_two, "monkey_slave") # looks for a file that was written to the slave
        verify_master(s_two)

        do_init_slave(s_one)
        # s_one is slave
        # s_two is master
        create_table_replication(s_two, "replication_works")
        check_table_replication(s_one, "replication_works")
      end

      def promote_slave_with_dead_master
        verify_master(s_one)

        do_init_slave(s_two)
        run_script("do_force_reset", s_one) # kill the master

        do_promote_to_master(s_two)
        verify_master(s_two)

        do_init_slave(s_one)

        # verify master slave with replication
        create_table_replication(s_two, "dead_master")
        check_table_replication(s_one, "dead_master")

        check_table_bananas(s_one)
        check_table_bananas(s_two)
      end

    end
  end
end
