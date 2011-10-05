set :runner, VirtualMonkey::Runner::MysqlChefHA

# s_one - the first server that is used to create a DB from scratch in order to get a valid
# backup for additional testing.
# s_two - the first real master  created from do_restore_and_become_master using the from
# scracth backup
# s_three - the first slave restored from a newly launched state.
#

# Terminates servers if there are any running
hard_reset do
  stop_all
end

before do
   mysql_lookup_scripts
   set_variation_lineage
   set_variation_container
   setup_dns("dnsmadeeasy_new") # dnsmadeeasy
   set_variation_dnschoice("text:DNSMadeEasy") # set variation choice
   launch_all
   wait_for_all("operational")

   disable_db_reconverge # it is important to disable this if we want to verify what backup we are restoring from

   # Need to setup a master from scratch to get the first backup for remaining tests
   #   tag/update dns for master
   #   create a block device
   #   add test tables into db
   #   write the backup
   run_script("do_tag_as_master", s_one)
   run_script("setup_block_device", s_one)
   create_monkey_table(s_one)
   #deletes backup, file, does backup, and waits for snapshot to complete
   do_backup(s_one)

   # Now we have a backup that can be used to restore master and slave
   # This server is not a real master.  To create a real master the
   # restore_and_become_master recipe needs to be run on a new instance
   # This one should be re-launched before additional tests are run on it
   transaction { s_one.relaunch }
end

test  "sequential_test" do
  sequential_test
end
#  reboot a slave, verify that it is operational, then add a table to master and verity replication
#  reboot the master, verify opernational - " " ^

#TODO checks for master vs slave backup setups
#  need to verify that the master servers backup cron job is using the master backup cron/minute/hour
#TODO enable and disable backups on both the master and slave servers

after "sequential_test" do
   #  reboot a slave, verify that it is operational, then add a table to master and verity replication
   #  reboot the master, verify opernational - " " ^
   # looks for a file that was written to the slave

   check_monitoring
   check_mysql_monitoring
   run_reboot_operations
   check_table_bananas(s_two)
   check_table_replication(s_two)
   check_slave_backup(s_two)
   check_monitoring
   check_mysql_monitoring

end

test "secondary_backup_s3" do
  test_secondary_backup_ha("S3")
end

test "secondary_backup_cloudfiles" do
  test_secondary_backup_ha("CloudFiles")
end

after 'primary_backup', 'secondary_backup_s3', 'secondary_backup_cloudfiles', 'reboot' do
  cleanup_volumes
end

after do
@runner.release_dns
#  cleanup_volumes
#  cleanup_snapshots
end

test "reboot" do
   run_script("setup_block_device", s_one)
   create_monkey_table(s_one)
do_backup(s_one)
end
