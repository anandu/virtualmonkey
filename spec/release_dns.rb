require File.join(File.dirname(__FILE__), "spec_helper")
require 'ruby-debug'

x=SharedDns.new("dnsmadeesy_new")
x.release_all
