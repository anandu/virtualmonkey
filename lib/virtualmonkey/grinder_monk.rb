require 'rubygems'
require 'erb'
require 'fog'
require 'eventmachine'
require 'right_popen'

class GrinderJob
  attr_accessor :status, :output, :logfile, :deployment, :rest_log, :other_logs, :no_resume, :verbose, :err_log
  # Metadata is a hash containing the following fields:
  #   user => { "email" => `git config user.email`.chomp,
  #             "name" => `git config user.name`.chomp }
  #   multicloudimage => { "name" => MultiCloudImage.name,
  #                        "href" => MultiCloudImage.href,
  #                        "os" => "CentOS|Ubuntu|Windows",
  #                        "os_version" => "5.4|5.6|10.04|2008R2|2003",
  #                        "arch" => "i386|x64",
  #                        "rightlink" => "5.6.32|5.7.14",
  #                        "rev" => 14,
  #                        "id" => 41732 }
  #   servertemplates => [{ "name" => ServerTemplate.nickname,
  #                         "href" => ServerTemplate.href,
  #                         "id" => 432672,
  #                         "rev" => 10 },
  #                       ...]
  #   cloud => { "name" => Cloud.name,
  #              "id" => Cloud.cloud_id }
  #   feature => ["base.rb", ...]
  #   instancetype => { "href" => InstanceType.href,
  #                     "name" => InstanceType.name }
  #   datacenter => { "name" => Datacenter.name,
  #                   "href" => Datacenter.href }
  #   troop => "base.json"
  #   report => nil until finished
  #   tags => ["sprint28", "regression", ...] (From @@options[:report_tags])
  #   time => GrinderMonk.log_started
  #   status => "pending|running|failed|passed" (or, manually, "blocked" or "willnotdo")
  attr_accessor :metadata

  def link_to_rightscale
#    i = deployment.href.split(/\//).last
#    d = deployment.href.split(/\./).first.split(/\//).last
#    "https://#{d}.rightscale.com/deployments/#{i}#auditentries"
    deployment.href.gsub(/api\//,"") + "#auditentries"
  end

  # stdout hook for popen3
  def on_read_stdout(data)
    data_ary = data.split("\n")
    data_ary.each_index do |i|
      data_ary[i] = timestamp + data_ary[i]
      $stdout.syswrite("<#{deploy_id}>#{data_ary[i]}\n".apply_color(:uncolorize)) if @verbose
    end
    File.open(@logfile, "a") { |f| f.write("#{data_ary.join("\n")}\n".apply_color(:uncolorize)) }
  end

  # stderr hook for popen3
  def on_read_stderr(data)
    data_ary = data.split("\n")
    data_ary.each_index do |i|
      data_ary[i] = timestamp + data_ary[i]
      $stdout.syswrite("<#{deploy_id}>#{data_ary[i]}\n".apply_color(:uncolorize, :yellow))
    end
    File.open(@logfile, "a") { |f| f.write("#{data_ary.join("\n")}\n".apply_color(:uncolorize)) }
    File.open(@err_log, "a") { |f| f.write("#{data_ary.join("\n")}\n".apply_color(:uncolorize)) }
  end

  def timestamp
    t = Time.now
    "#{t.strftime("[%m/%d/%Y %H:%M:%S.")}%06d] " % t.usec
  end

  def deploy_id
    @id = deployment.rs_id
  end

  # on_exit hook for popen3
  def on_exit(status)
    @status = status.exitstatus
  end

  # Launch an asynchronous process
  def run(cmd)
    RightScale.popen3(:command        => cmd,
                      :target         => self,
                      :environment    => {"AWS_ACCESS_KEY_ID" => Fog.credentials[:aws_access_key_id],
                                          "AWS_SECRET_ACCESS_KEY" => Fog.credentials[:aws_secret_access_key],
                                          "REST_CONNECTION_LOG" => @rest_log,
                                          "MONKEY_NO_DEBUG" => "true",
                                          "MONKEY_LOG_BASE_DIR" => File.dirname(@rest_log)},
                      :stdout_handler => :on_read_stdout,
                      :stderr_handler => :on_read_stderr,
                      :exit_handler   => :on_exit)
  end
end

class GrinderMonk
  attr_accessor :jobs
  attr_accessor :options

  def self.combo_feature_name(features)
    File.join(VirtualMonkey::FEATURE_DIR, features.map { |feature| File.basename(feature, ".rb") }.join("_") + ".combo.rb")
  end

  def determine_rightlink_version(mci, regex)
    mci.find_and_flatten_settings
    settings_ary = mci.multi_cloud_image_cloud_settings
    settings_ary.each { |setting|
      if setting.is_a?(MultiCloudImageCloudSettingInternal)
        return (setting.image_name =~ regex; $3)
      elsif setting.is_a?(McMultiCloudImageCloudSetting)
        if image = McImage.find(setting.image)
          return (image.name =~ regex; $3)
        end
      end
    }
  end

  # Runs a grinder test on a single Deployment
  # * deployment<~String> the nickname of the deployment
  # * feature<~String> the feature filename
  def build_job(deployment, feature, test_ary, other_logs = [])
    new_job = GrinderJob.new
    new_job.logfile = File.join(@log_dir, "#{deployment.nickname}.log")
    new_job.err_log = File.join(@log_dir, "#{deployment.nickname}.stderr.log")
    new_job.rest_log = File.join(@log_dir, "#{deployment.nickname}.rest_connection.log")
    new_job.other_logs = other_logs.map { |log|
      File.join(@log_dir, "#{deployment.nickname}.#{File.basename(log)}")
    }
    new_job.deployment = deployment
    new_job.verbose = true if @options[:verbose]
    grinder_bin = File.join(VirtualMonkey::BIN_DIR, "grinder")
    cmd = "\"#{grinder_bin}\" -f \"#{feature}\" -d \"#{deployment.nickname}\" -t "
    test_ary.each { |test| cmd += " \"#{test}\" " }
    cmd += " -r " if @options[:no_resume]

    if @options[:report_metadata] && false # TODO: Remove false after WebUI is finished
      # Build Job Metadata
      puts "\nBuilding Job Metadata...\n\n"
      data = {}

      ###################
      # Filterable Data #
      ###################

      # User Data
      puts "\nGathering User Data...\n\n"
      describe_metadata_fields("user").each { |f| data["user_#{f}"] = `git config user.#{f}`.chomp }

      # MultiCloudImage Data
      puts "\nGathering MultiCloudImage Data...\n\n"
      describe_metadata_fields("mci").each { |f| data["mci_#{f}"] = [] }
      deployment.get_info_tags["self"].each { |key,val|
        if key =~ /mci_id/
          mci = MultiCloudImage.find(val.to_i)
          data["mci_name"] |= [mci.name]
          data["mci_href"] |= [mci.href]
          data["mci_rev"] |= [mci.version]
          data["mci_id"] |= [mci.rs_id]

          # Extra Info
          regex = /(.)*/
          if mci.name =~ /CentOS/i
            data["mci_os"] |= ["CentOS"]
            #        CentOS  Version   Arch    RightLink
            regex = /CentOS_([.0-9]*)_([^_]*)_v([.0-9]*)/i
          elsif mci.name =~ /Ubuntu/i
            data["mci_os"] |= ["Ubuntu"]
            #        Ubuntu  Version Nickname    Arch    RightLink
            regex = /Ubuntu_([.0-9]*)[_a-zA-Z]*_([^_]*)_v([.0-9]*)/i
          elsif mci.name =~ /Windows/i
            data["mci_os"] |= ["Windows"]
            #        Windows  Version   ServicePack  Arch    App    RightLink
            regex = /Windows_([0-9A-Za-z]*[_SP0-9]*)_([^_]*)[\w.]*_v([.0-9]*)/i
          end
          data["mci_os_version"] |= [(mci.name =~ regex; $1)]
          data["mci_arch"] |= [(mci.name =~ regex; $2)]
          data["mci_rightlink"] |= [determine_rightlink_version(mci, regex)]
        end
      }

      # ServerTemplate Data
      puts "\nGathering ServerTemplate Data...\n\n"
      describe_metadata_fields("servertemplate").each { |f| data["servertemplate_#{f}"] = [] }
      deployment.servers.each { |server|
        server.settings
        st = ServerTemplate.find(server.server_template_href)
        data["servertemplate_name"] |= [st.nickname]
        data["servertemplate_href"] |= [st.href]
        data["servertemplate_rev"] |= [st.version]
        data["servertemplate_id"] |= [st.rs_id]
      }

      # Cloud Data
      puts "\nGathering Cloud Data...\n\n"
      describe_metadata_fields("cloud").each { |f| data["cloud_#{f}"] = [] }
      cloud_id = deployment.get_info_tags["self"]["cloud"]
      clouds = VirtualMonkey::Toolbox.get_available_clouds
      if cloud_id != "multicloud"
        data["cloud_id"] |= [cloud_id.to_i]
        data["cloud_name"] |= [clouds.detect { |hsh| hsh["cloud_id"] == cloud_id.to_i }["name"]]
      else
        deployment.servers_no_reload.each { |server|
          scid = server.cloud_id.to_i
          data["cloud_id"] |= [scid]
          data["cloud_name"] |= [clouds.detect { |hsh| hsh["cloud_id"] == scid.to_i }["name"]]
        }
      end

      # InstanceType Data
      puts "\nGathering InstanceType Data...\n\n"
      describe_metadata_fields("instancetype").each { |f| data["instancetype_#{f}"] = [] }
      deployment.servers_no_reload.each { |server|
        if server.multicloud
          if server.current_instance
            data["instancetype_href"] |= [server.current_instance.instance_type]
            data["instancetype_name"] |= [McInstanceType.find(server.current_instance.instance_type).name]
          else
            data["instancetype_href"] |= [server.next_instance.instance_type]
            data["instancetype_name"] |= [McInstanceType.find(server.next_instance.instance_type).name]
          end
        else
          data["instancetype_name"] |= [server.ec2_instance_type]
        end
      }

      # Datacenter Data
      puts "\nGathering Datacenter Data...\n\n"
      deployment.servers_no_reload.each { |server|
        if server.multicloud
          describe_metadata_fields("datacenter").each { |f| data["datacenter_#{f}"] ||= [] }
          data["datacenter_href"] |= [server.datacenter]
          data["datacenter_name"] |= [Datacenter.find(server.datacenter).name]
        end
      }

      # Troop File Data
      puts "\nGathering Troop Data...\n\n"
      data["troop"] = [@options[:config_file]]

      # Run Tags Data
      data["tag"] = @options[:report_tags] || []

      # Date Data
      data["date"] = @started_at.strftime("%Y_%m_%d")

      #####################
      # Extra Report Data #
      #####################

      # Feature File Data
      data["status"] = "running" # status => "pending|running|failed|passed" (or, manually, "blocked" or "willnotdo")
      data["report_page"] = nil # nil until first upload
      data["time"] = @started_at.strftime("%H:%M:%S")
      data["feature"] = [feature] # TODO: Gather runner info and runner option info?
      data["command_create"] = deployment.get_info_tags["self"]["command"]
      data.delete("command_create") unless data["command_create"]
      data["command_run"] = VirtualMonkey::Command::last_command_line

      # Unique JobID
      data["job_id"] = "#{@started_at.strftime("%Y_%m_%d_%H_%M_%S")}_#{deployment.rs_id}"

      new_job.metadata = data
    end

    [new_job, cmd]
  end

  def run_test(deployment, feature, test_ary, other_logs = [])
    new_job, cmd = build_job(deployment, feature, test_ary, other_logs)
    @jobs << new_job

    cmd += " -g "
    puts "running #{cmd}"
    new_job.run(cmd)
  end

  def exec_test(deployment, feature, test_ary, other_logs = [])
    unless VirtualMonkey::config[:grinder_subprocess] == "force_subprocess"
      new_job, cmd = build_job(deployment, feature, test_ary, other_logs)
      warn "\n========== Loading Grinder into current process! =========="
      warn "\nSince you only have one deployment, it would probably be of more use to run the developer tool"
      warn "Grinder directly. The command:\n\n#{cmd}\n\nwill replace the current process."
      warn "\nPress Ctrl-C in the next 15 seconds to run Grinder in a subprocess rather than this one."
      exec(cmd) if VirtualMonkey::Command::countdown(15)
    end
    run_test(deployment, feature, test_ary, other_logs)
  end

  def initialize()
    @started_at = Time.now
    @jobs = []
    @passed = []
    @failed = []
    @running = []
    dirname = @started_at.strftime(File.join("%Y", "%m", "%d", "%H-%M-%S"))
    @log_dir = File.join(VirtualMonkey::ROOTDIR, "log", dirname)
    @log_started = dirname
    FileUtils.mkdir_p(@log_dir)
    @feature_dir = File.join(VirtualMonkey::ROOTDIR, 'features')
  end

  # runs a feature on an array of deployments
  # * deployments<~Array> array of strings containing the nicknames of the deployments
  # * feature_name<~String> the feature filename
  def run_tests(deploys, features, set=[])
    features = [features].flatten
    test_cases = features.map_to_h { |feature| VirtualMonkey::TestCase.new(feature, @options) }
    deployment_hsh = {}
    if VirtualMonkey::config[:feature_mixins] == "parallel" or features.length < 2
      raise "Need more deployments than feature files" unless deploys.length >= features.length
      dep_clone = deploys.dup
      deps_per_feature = (deploys.length.to_f / features.length.to_f).floor
      deployment_hsh = features.map_to_h { |f|
        dep_clone.shuffle!
        dep_clone.slice!(0,deps_per_feature)
      }
    else
      combo_feature = GrinderMonk.combo_feature_name(features)
      File.open(combo_feature, "w") { |f|
        f.write(features.map { |feature| "mixin_feature '#{feature}', :hard_reset" }.join("\n"))
      }
      test_cases[combo_feature] = VirtualMonkey::TestCase.new(combo_feature, @options)
      deployment_hsh = { combo_feature => deploys }
    end

    if deploys.size == 1 && VirtualMonkey::Command::last_command_line !~ /^troop/ && !@options[:report_metadata]
      feature = deployment_hsh.first.first
      d = deployment_hsh.first.last.last
      total_keys = test_cases[feature].get_keys
      total_keys &= set unless set.nil? || set.empty?

      unless VirtualMonkey::config[:test_ordering] == "strict"
        deployment_tests = [total_keys].map { |ary| ary.shuffle }
      end

      exec_test(d, feature, deployment_tests[0], test_cases[feature].options[:additional_logs])
    else
      deployment_hsh.each { |feature,deploy_ary|
        total_keys = test_cases[feature].get_keys
        total_keys &= set unless set.nil? || set.empty?
        if VirtualMonkey::config[:test_permutation] == "exhaustive"
          deployment_tests = [total_keys] * deploy_ary.length
        else
          keys_per_dep = (total_keys.length.to_f / deploy_ary.length.to_f).ceil

          deployment_tests = []
          (keys_per_dep * deploy_ary.length).times { |i|
            di = i % deploy_ary.length
            deployment_tests[di] ||= []
            deployment_tests[di] << total_keys[i % total_keys.length]
          }
        end

        deployment_tests.map! { |ary| ary.shuffle } unless VirtualMonkey::config[:test_ordering] == "strict"

        deploy_ary.each_with_index { |d,i|
          run_test(d, feature, deployment_tests[i], test_cases[feature].options[:additional_logs])
        }
      }
    end
  end

  # Print status of jobs. Also watches for jobs that had exit statuses other than 0 or 1
  def watch_and_report
    old_passed = @passed
    old_failed = @failed
    old_running = @running
    old_sum = old_passed.size + old_failed.size + old_running.size
    @passed = @jobs.select { |s| s.status == 0 }
    @failed = @jobs.select { |s| s.status != 0 && s.status != nil }
    @running = @jobs.select { |s| s.status == nil }
    new_sum = @passed.size + @failed.size + @running.size

    passed_string = " #{@passed.size} features passed. "
    passed_string = passed_string.apply_color(:green) if @passed.size > 0

    failed_string = " #{@failed.size} features failed. "
    failed_string = failed_string.apply_color(:red) if @failed.size > 0

    running_string = " #{@running.size} features running "
    running_string = running_string.apply_color(:cyan) if @running.size > 0
    running_string += "for #{Time.now - @started_at}"

    puts(passed_string + failed_string + running_string)
    if new_sum < old_sum and new_sum < @jobs.size
      warn "WARNING: Jobs Lost! Finding...".apply_color(:yellow)
      report_lost_deployments({ :old_passed => old_passed, :passed => @passed,
                                :old_failed => old_failed, :failed => @failed,
                                :old_running => old_running, :running => @running })
    end
    if old_passed != @passed || old_failed != @failed
      status_change_hook
    end
  end

  def status_change_hook
    begin
      generate_reports
      if all_done?
        puts "monkey done."
        EM.stop
      end
    rescue Interrupt => e
      raise
    rescue Exception => e
      warn "#{e}\n#{e.backtrace.join("\n")}"
    end
  end

  def all_done?
    running = @jobs.select { |s| s.status == nil }
    running.size == 0 && @jobs.size > 0
  end

  # Generates monkey reports and uploads to S3
  def generate_reports
    report_url = VirtualMonkey::Report.update_s3(@jobs, @log_started)
    puts "    new results available at #{report_url}"
=begin
    TODO: Uncomment after WebUI is finished
    if @options[:report_metadata]
      @jobs.each { |job|
        job.metadata["report_page"] = report_url
        job.metadata["status"] = (job.status == 0 ? "passed" : "failed") if job.status
      }
      VirtualMonkey::Report.update_sdb(@jobs)
      puts "SimpleDB updated"
    end
=end
  end

  # Prints information on jobs that didn't have an exit code of 0 or 1
  def report_lost_deployments(jobs = {})
    running_change = jobs[:old_running] - jobs[:running]
    passed_change = jobs[:passed] - jobs[:old_passed]
    failed_change = jobs[:failed] - jobs[:old_failed]
    lost_jobs = running_change - passed_change - failed_change
    lost_jobs.each do |j|
      warn "LOST JOB---------------------------------"
      warn "Deployment Name: #{j.deployment.nickname}"
      warn "Status Code: #{j.status}"
      warn "Audit Entries: #{j.link_to_rightscale}"
      warn "Log File: #{j.logfile}"
      warn "Rest_Connection Log File: #{j.rest_log}"
      warn "-----------------------------------------"
    end
  end

  def describe_metadata_fields(type=nil)
     fields = {
      "user" => ["email", "name"],
      "mci" => ["name", "href", "os", "os_version", "arch", "rightlink", "rev", "id"],
      "servertemplate" => ["name", "href", "id", "rev"],
      "cloud" => ["name", "id"],
      "feature" => [],
      "instancetype" => ["name", "href"],
      "datacenter" => ["name", "href"],
      "troop" => [],
      "report_page" => [],
      "tag" => [],
      "time" => [],
      "date" => [],
      "command" => ["create", "run"],
      "status" => [],
    }
    (type ? fields[type] : fields.keys)
  end
end
