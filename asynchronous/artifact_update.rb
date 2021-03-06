#!/opt/chef/embedded/bin/ruby

#
# artifact_update
#
# Copyright 2013, CollabNet, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'net/http'
require 'syslog'
require 'rubygems'
require 'chef/config'
require 'chef/log'
require 'chef/rest'
require 'chef/data_bag'
require 'chef/data_bag_item'
require 'chef/mixin/shell_out'

include Chef::Mixin::ShellOut

if RUBY_VERSION < "1.9"
  print "Ruby 1.9.x is required to use this script. Please use the Ruby that comes with Chef."
  exit 1
end

# Use the same config as knife uses
Chef::Config.from_file(File.join(ENV['HOME'], '.chef', 'knife.rb'))

# Begin global variables
bagname = "deploy"
target_node_field = "Deploy To"
frsid_field = "FRSID"
deploy_status = 'Deploy'
# End global variables

syslog = Syslog.open(::File::basename($0), Syslog::LOG_PID, Syslog::LOG_DAEMON | Syslog::LOG_LOCAL3)

tf_vars = ENV.to_hash.select { |k,v| k =~ /^tf_/ }
tf_original_flex_field_vars = tf_vars.select { |k,v| k=~ /^tf_original_flex_field_/ }
tf_updated_flex_field_vars = tf_vars.select { |k,v| k=~ /^tf_updated_flex_field_/ }

# Find whether there was a status change and the new status is something that we are looking for.
if tf_vars['tf_original_Status'] == tf_vars['tf_updated_Status'] then
  syslog.crit("No change in status field, skipping this event.")
  exit 1
elsif tf_vars['tf_updated_Status'] != deploy_status then
  syslog.crit("Status change is not expected status '#{deploy_status}', skipping this event.")
  exit 1
end


# Find the corresponding values for the vars of interest;
# We're looking for the value of the flex fields named:
#
# "Deploy To" -- which we set as 'target_node'
# "FRSID" -- which we set as 'frsid'

original_target_node, original_frsid, updated_target_node, updated_frsid = nil

tf_original_flex_field_vars.each do |k, v|
  if v == target_node_field then
    original_target_node = tf_original_flex_field_vars[k.sub(/name/, 'value')]
    syslog.debug("original target_node set to " + original_target_node)
  end
  if v == frsid_field then
    original_frsid = tf_original_flex_field_vars[k.sub(/name/, 'value')]
    syslog.debug("original frsid set to " + original_frsid)
  end
end

if (original_target_node.nil? || original_frsid.nil?) then
  syslog.crit("Required original fields not defined in tracker; can't proceed")
  exit 1
end

tf_updated_flex_field_vars.each do |k, v|
  if v == target_node_field then
    updated_target_node = tf_updated_flex_field_vars[k.sub(/name/, 'value')]
    syslog.debug("updated target_node set to " + updated_target_node)
  end
  if v == frsid_field then
    updated_frsid = tf_updated_flex_field_vars[k.sub(/name/, 'value')]
    syslog.debug("updated frsid set to " + updated_frsid)
  end
end

if (updated_target_node.nil? || updated_frsid.nil?) then
  syslog.crit("Required updated fields not defined in tracker; can't proceed")
  exit 1
end

# Make sure data bag exists
begin
  bag = Chef::DataBag.load(bagname)
rescue Net::HTTPServerException => e
  if e.response.code == "404" then
    syslog.debug("Creating a new data bag named " + bagname)
    bag = Chef::DataBag.new
    bag.name(bagname)
    bag.save
  else
    syslog.crit("Received an HTTPException of type " + e.response.code)
    raise
  end
end

# Load data bag item, or create it if it doesn't exist yet
item_id = "#{updated_target_node.gsub(/\./, '_')}_param"
begin
  item = Chef::DataBagItem.load(bagname, item_id)
rescue Net::HTTPServerException => e
  if e.response.code == "404" then
    syslog.debug("Creating a new data bag item named " + item_id + " in data bag " + bagname)
    item = Chef::DataBagItem.new
    item.data_bag(bagname)
    item['id'] = item_id
  else
    syslog.crit("Received an HTTPException of type " + e.response.code)
    raise
  end
end

item[item_id].nil? && item[item_id] = Hash.new
item[item_id]["frsid"] = updated_frsid
item[item_id]["artifact_id"] = tf_vars['tf_updated_Id']
item[item_id]["tracker_id"] = tf_vars['tf_updated_FolderId']
item.save

# Exec knife to log into remote and run Chef once
cmd = shell_out!("knife ssh 'name:#{updated_target_node}' '[ -e /var/run/chef/client.pid ] && sudo /usr/bin/pkill -USR1 chef-client || sudo /usr/bin/chef-client --once'")

# If the above command fails an exception is thrown and if it succeeds and DEBUG
# is enabled the output is logged.
if ENV['DEBUG'] == '1' then
  puts cmd.stdout
end
