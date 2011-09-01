module VirtualMonkey
  module Runner
    class SimpleWindowsIIS
      include VirtualMonkey::Mixin::DeploymentBase
      include VirtualMonkey::Mixin::SimpleWindows
  
      def server_ad
          @servers.select { |s| s.nickname =~ /Microsoft IIS App/i }.first
      end
  
      def oleg_windows_iis_lookup_scripts
       scripts = [
                   [ 'SYS Timezone set', 'SYS Timezone set' ],
                   [ 'IIS Download application code', 'IIS Download application code' ],
                   [ 'IIS Add connection string', 'IIS Add connection string' ],
                   [ 'IIS Switch default website', 'IIS Switch default website' ],
                   [ 'IIS Restart application', 'IIS Restart application' ],
                   [ 'IIS Restart web server', 'IIS Restart web server' ],
                   [ 'DB SQLS Download and attach db', 'DB SQLS Download and attach db' ],
                   [ 'DB SQLS Create login', 'DB SQLS Create login' ],
                   [ 'AWS Register with ELB', 'AWS Register with ELB' ],
                   [ 'AWS Deregister from ELB', 'AWS Deregister from ELB' ],
                   [ 'SYS install MSDeploy2.0', 'SYS install MSDeploy2.0' ],
                 ]
        st = ServerTemplate.find(resource_id(server_ad.server_template_href))
        load_script_table(st,scripts)
#        load_script('DB SQLS Create login check', RightScript.new('href' => "/api/acct/29082/right_scripts/430024"))
        load_script('SYS install MSDeploy2.0 check', RightScript.new('href' => "/api/acct//29082/right_scripts/430037"))
        load_script('IIS Restart web server check', RightScript.new('href' => "/api/acct//29082/right_scripts/430040"))
        load_script('IIS monkey tests', RightScript.new('href' => "/api/acct//29082/right_scripts/430759"))
      end
    end
  end
end