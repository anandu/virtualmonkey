module VirtualMonkey
  module Command
    # This command does all the steps create/run/conditionaly destroy
    def self.new_config(*args)
      self.init(*args)
      @@options = Trollop::options do
        text @@available_commands[:new_config]
      end
      #raise "You must select a single cloud id to create a singe deployment" if( @@options[:single_deployment] && (@@options[:cloud_override] == nil || @@options[:cloud_override].length != 1))  # you must select at most and at minimum 1 cloud to work on when the -z is selected
      # PATHs SETUP
      features_glob = Dir.glob(File.join(@@features_dir, "**")).collect { |c| File.basename(c) }
      cloud_variables_glob = Dir.glob(File.join(@@cv_dir, "**")).collect { |c| File.basename(c) }
      common_inputs_glob = Dir.glob(File.join(@@ci_dir, "**")).collect { |c| File.basename(c) }
      name = ask("Filename?").strip
      @@troop_file = File.join(@@troop_dir, "#{name}.json")

      # CREATE NEW CONFIG
      @@troop_config = {}
      @@troop_config[:prefix] = ask("What prefix to use for creating the deployments?")
      @@troop_config[:server_template_ids] = ask("What Server Template ids (or names) would you like to use to create the deployments (comma delimited)?").split(",")
      @@troop_config[:server_template_ids].each {|st| st.strip!}

      # TODO: Multicloud Deployments
      puts "Available Clouds:"
      VirtualMonkey::Toolbox::get_available_clouds().each { |c| puts "#{c['cloud_id']}: #{c['name']}" }
      list_of_clouds = ask("Enter a comma-separated list of cloud_ids to use").split(",")
      @@troop_config[:clouds] = list_of_clouds.map { |c| c.to_i }

      @@troop_config[:common_inputs] =
        choose do |menu|
          menu.prompt = "Which common_inputs config file?"
          menu.index = :number
          menu.choices(*common_inputs_glob)
        end

      @@troop_config[:feature] = 
        choose do |menu|
          menu.prompt = "Which feature file?"
          menu.index = :number
          menu.choices(*features_glob)
        end
      
      write_troop_file()
      say("Created config file: #{@@troop_file}")
      say("Done.")
    end
  end
end
