if require 'ruby-debug'
  Debugger.start() if ENV['MONKEY_NO_DEBUG'] != "true" and ENV['ENTRY_COMMAND'] == "grinder"
end

# Hash Patches

class Hash
  # test_case_interface hook for nice printing
  def trace_inspect
    inspect
  end

  def to_h
    self
  end
end

# Array Patches

class Array
  # test_case_interface hook for nice printing
  def trace_inspect
    inspect
  end

  # Experimental code for applying a method to each element in an Array
  def method_missing(method_name, *args, &block)
    if self.all? { |item| item.respond_to?(method_name) }
      return self.collect { |item| item.__send__(method_name, *args, &block) }
    else
      raise NoMethodError.new("undefined method '#{method_name}' for Array")
    end
  end

  def uniq_by(&block)
    transforms = {}
    reject do |elem|
      t = block[elem]
      should_reject = transforms[t]
      transforms[t] = true
      should_reject
    end
  end

  def uniq_by!(&block)
    transforms = {}
    reject! do |elem|
      t = block[elem]
      should_reject = transforms[t]
      transforms[t] = true
      should_reject
    end
  end

  def unanimous?(&block)
    a = block[first]
    ret = true
    each_with_index do |elem,index|
      next if index == 0
      ret &&= (a == block[elem])
      break unless ret
    end
    ret
  end

  def to_h(name_key="name", value_key="value")
    raise "Elements are not unique!" unless self == uniq
    ret = {}
    each_with_index do |elem,index|
      if elem.is_a?(Hash)
        if elem[name_key] and elem[value_key] and elem.length == 2
          ret[elem[name_key]] = elem[value_key]
        elsif elem[name_key.to_s] and elem[value_key.to_s] and elem.length == 2
          ret[elem[name_key.to_s]] = elem[value_key.to_s]
        elsif elem[name_key.to_sym] and elem[value_key.to_sym] and elem.length == 2
          ret[elem[name_key.to_sym]] = elem[value_key.to_sym]
        else
          changed = ((ret.keys - elem.keys) != ret.keys)
          raise "Collision detected in Array->Hash conversion" if changed
          ret.merge! elem
        end
      elsif elem.is_a?(Array)
        if elem.length == 2
          ret[elem.first] = elem.last
        elsif elem.length > 2
          ret[elem.first] = elem[1..-1]
        else
          ret[index] = elem.first
        end
      else
        ret[index] = elem
      end
    end
    ret
  end

  def to_hash
    to_h
  end

  def map_to_h(&block)
    [self, map(&block)].transpose.to_h
  end
end

module Math
  # Added Absolute Value function
  def self.abs(n)
    (n > 0 ? n : 0 - n)
  end
end

module RightScale
  module Api
    module Base
#      include VirtualMonkey::TestCaseInterface
      alias_method :old_inspect, :inspect

      # test_case_interface hook for nice printing
      def trace_inspect
        inspect
      end

      # test_case_interface hook for nice printing
      def inspect
        val = nil
        if self.nickname
          val = self.nickname.inspect
        elsif self.name
          val = self.name.inspect
        elsif self.rs_id
          val = self.rs_id
        end
        return "#{self.class.to_s}[#{val}]"
      end
    end
  end
end

class String
  # test_case_interface hook for nice printing
  def trace_inspect
    inspect
  end

  def uncolorize
    self.gsub(/\e\[0[;0-9]*m/, "")
  end

  def colorized?
    !(self =~ /\e\[0[;0-9]*m/).nil?
  end

  def apply_color(*color_symbols)
    ret = self
    if VirtualMonkey::config[:colorized_text] != "hide"
      color_symbols.each { |color| ret = ret.__send__(color) }
    end
    ret
  end
end

class Symbol
  # test_case_interface hook for nice printing
  def trace_inspect
    inspect
  end
end

class Fixnum
  # test_case_interface hook for nice printing
  def trace_inspect
    inspect
  end
end

class NilClass
  # test_case_interface hook for nice printing
  def trace_inspect
    inspect
  end
end

class ServerInterface
  # test_case_interface hook for nice printing
  def trace_inspect
    @impl.trace_inspect
  end
end

class Object
  def warn(*args, &block)
    if args.first.is_a?(String)
      args[0] = args[0].apply_color(:uncolorize, :yellow)
    end
    super(*args, &block)
  end

  def error(string)
    STDERR.puts(string.apply_color(:uncolorize, :red))
    exit(1)
  end

  def just_my_methods
    ret = self.methods - self.class.superclass.new.methods
    self.included_modules.each { |mod| ret -= mod.methods }
    ret
  end
end
