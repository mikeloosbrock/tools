#!/usr/bin/env ruby

require 'erb'
require 'optparse'
require 'json'
require 'yaml'
require 'pp'

module Loosbrock
  module ErbT
    def self.build_vars(vars,srcs)
      if srcs.class == String
        default = srcs
        srcs = {}
        srcs.default = default
      end
      new_vars = {}
      vars.each do |var,val|
        new_vars[var] = { :val => val, :src => srcs[var] }
      end
      return new_vars
    end
    #==========================================================================#
    #
    #
    #
    class RenderContext
      attr_accessor :ignore_undefined_vars, :default_vars, :debug_level
      #------------------------------------------------------------------------#
      def initialize(erb_str,erb_src='INPUT-ERB',def_vars={})
        @erb_str          = erb_str.untaint
        @def_vars         = def_vars.clone
        @includes         = {}.untrust
        @include_stack    = [erb_src].untrust
        @debug_level      = 3
        @erb_trace_lines  = [].untrust
        @erb_trace_indent = [].untrust
      end
      #------------------------------------------------------------------------#
      def debug(level,msg)
        if level <= @debug_level
          msg.each_line do |line|
            STDERR.puts("[DEBUG] #{line}")
          end
        end
      end
      #------------------------------------------------------------------------#
      def erb_trace(msg)
        msg.each_line do |line|
          #line = "#{@erb_trace_indent.join('')}#{msg_line.to_s.rstrip}"
          #if @erb_trace_lines[-1] =~ /^#{line}( \(repeated (\d+) times\))?/
          #  count = $2.to_i + 1
          #  @erb_trace_lines[-1] = "#{line} (repeated #{count} times)"
          #else
          #  @erb_trace_lines << "#{@erb_trace_indent.join('')}#{line.rstrip}"
          #end
          @erb_trace_lines << "#{@erb_trace_indent.join('')}#{line.rstrip}"
        end
      end
      #------------------------------------------------------------------------#
      def preload_includes(str)
        str.scan(/\s+erbt_(load|insert)_file\(?\s*("|')(\S+?)("|')/) do |match|
          include_file = $3
          if @includes.keys.include?(include_file)
            debug(1,"Preloading #{include_file}... already loaded, skipping it.")
            next
          end
          debug(1,"Preloading #{include_file}...")
          include_str = File.read(include_file)
          @includes[include_file] = include_str.taint
          preload_includes(include_str)
        end
      end
      #------------------------------------------------------------------------#
      def render(vars={},trim='>')
        erb_str = @erb_str.untaint
        @includes = {}
        preload_includes(erb_str)
        @vars = @def_vars.clone.untrust
        @vars.merge!(vars)
        debug(3,"Variables before rendering:")
        @vars.each do |var,hash|
          debug(3,"  #{var} = '#{hash[:val]}' (#{hash[:src]})")
        end
        b = binding().taint
        begin
          o = ERB.new(erb_str,4,trim).result(b)
        rescue => e
          line = e.backtrace[0].split(':')[1]
          raise "\nOh boy, this is not good. Like, really not good.\n" + \
                "There appears to be a mistake on line #{line} of the '#{@include_stack[-1]}' template.\n" + \
                "Specifically: #{e.to_s.split("\n")[0]}\n" + \
                "Hopefully you know how to fix this, 'cause I got nothin."
        end
        debug(2,"Trace:")
        debug(2,"  " + @erb_trace_lines.join("\n  "))
        debug(3,"Variables after rendering:")
        @vars.each do |var,hash|
          debug(3,"  #{var} = '#{hash[:val]}' (#{hash[:src]})")
        end
        return o
      end
      #------------------------------------------------------------------------#
      # All of the following methods are 'helpers' that can be invoked from    #
      # inside <% ... %> tags within erbt templates. They do 'helpful' things  #
      # like load/insert other (nested) templates and get/set/delete variables.#
      #------------------------------------------------------------------------#
      # Additional helper methods can be defined/registered from within the    #
      # templates themselves as well. Doing so adds the method to the global   #
      # binding (context) used by ERB. The intended use-case for this is       #
      # macro-like functionality.                                              #
      #------------------------------------------------------------------------#
      def define_helper(name,&block)
        erb_trace("define_helper('#{name}',&block)")
        self.class.send(:define_method,name,block)
      end
      #------------------------------------------------------------------------#
      # ERB-renders a file that was previously read using preload_includes()   #
      # and, unlike erbt_insert_file(), does _not_ return the eval results for #
      # expansion in the calling template. Use with <% ... %> tags.            #
      #------------------------------------------------------------------------#
      def erbt_load_file(file)
        erb_trace("load_file('#{file}'):")
        @erb_trace_indent.push('  ')
        @include_stack.push(file)
        ERB.new(@includes[file]).result(binding)
        @include_stack.pop()
        @erb_trace_indent.pop()
      end
      #------------------------------------------------------------------------#
      # ERB-renders a file that was previously read using preload_includes()   #
      # and, unlike erbt_load_file(), returns the eval results for expansion   #
      # in the calling template. Use with <%= ... %> tags.                     #
      #------------------------------------------------------------------------#
      def erbt_insert_file(file,indent='',trim=nil)
        erb_trace("insert_file('#{file}','#{indent}',#{trim.nil? ? 'nil' : "'#{trim}'"}):")
        @erb_trace_indent.push('  ')
        @include_stack.push(file)
        o = ERB.new(@includes[file],nil,trim).result(binding)
        @include_stack.pop()
        @erb_trace_indent.pop()
        o.lines.map!.with_index { |line,i| (i == 0 ? line : "#{indent}#{line}") }
        return o
      end
      #------------------------------------------------------------------------#
      # Gets the value of the @var variable.                                   #
      #------------------------------------------------------------------------#
      def get_var(var,default=nil)
        if @vars.key?(var)
          erb_trace("get_var('#{var}') => '#{@vars[var][:val]}' (set from #{@vars[var][:src]})")
          return @vars[var][:val]
        elsif @ignore_undefined_vars
          val = (default.nil? ? 'nil' : "'#{default}'")
          erb_trace("get_var('#{var}') => #{val} (undefined variable, returning the specified default)")
          return default
        else
          erb_trace("get_var('#{var}') =>")
          raise "Undefined variable '#{var}' was referenced."
        end
      end
      alias_method(:v,:get_var)
      #------------------------------------------------------------------------#
      # Gets the source of the @var variable.                                  #
      #------------------------------------------------------------------------#
      def get_src(var)
        if @vars.key?(var)
          erb_trace("get_src('#{var}') => '#{@vars[var][:src]}'")
          return @vars[var][:src]
        elsif @ignore_undefined_vars
          erb_trace("get_src('#{var}') => nil (undefined variable)")
          return nil
        else
          erb_trace("get_src('#{var}') =>")
          raise "Undefined variable '#{var}' was referenced."
        end
      end
      alias_method(:get_from,:get_src)
      alias_method(:f,:get_src)
      #------------------------------------------------------------------------#
      # Sets the @var variable's value to @val, and its source to @src.        #
      #------------------------------------------------------------------------#
      def set_var(var,val,src='set_var')
        erb_trace("set_var('#{var}','#{val}','#{src}')")
        @vars[var] = { :val => val, :src => "erbt::template::#{@include_stack[-1]}::#{src}" }
      end
      alias_method(:s,:set_var)
      #------------------------------------------------------------------------#
      # Sets all variables in the @vars hash.                                  #
      #------------------------------------------------------------------------#
      def set_vars(vars,src='set_vars')
        if vars.class != Hash
          raise "The first ('vars') argument to set_vars() must be a hash."
        end
        erb_trace("set_vars('#{vars}','#{src}') =>")
        @erb_trace_indent.push('  ')
        vars.each { |var,val| set_var(var,val,src) }
        @erb_trace_indent.pop()
      end
      #------------------------------------------------------------------------#
      # Sets the @var variable if it is currently undefined.                   #
      #------------------------------------------------------------------------#
      def set_var_if_undefined(var,val,src='set_var_if_undefined')
        erb_trace("set_var_if_undefined('#{var}','#{val}','#{src}')")
        set_var(var,val,src) if not @vars.key?(var)
      end
      #------------------------------------------------------------------------#
      # Sets all variables in the @vars hash that are currently undefined.     #
      #------------------------------------------------------------------------#
      def set_vars_if_undefined(vars,src='set_vars_if_undefined')
        if vars.class != Hash
          raise "The first ('vars') argument to set_vars_if_undefined() must be a hash."
        end
        erb_trace("set_vars_if_undefined(#{vars},'#{src}') =>")
        @erb_trace_indent.push('  ')
        vars.each { |var,val| set_var(var,val,src) if not @vars.key?(var) }
        @erb_trace_indent.pop()
      end
      #------------------------------------------------------------------------#
      # Sets the @var variable if its source matches the @from regex.          #
      #------------------------------------------------------------------------#
      def set_var_if_from(var,val,from,src='set_var_if_from')
        erb_trace("set_var_if_from('#{var}','#{val}','#{from}','#{src}')")
        set_var(var,val,src) if @vars.key?(var) and @vars[var][:src] =~ /#{from}/
      end
      #------------------------------------------------------------------------#
      # Sets all variables in the @vars hash with sources matching the @from   #
      # regex.                                                                 # 
      #------------------------------------------------------------------------#
      def set_vars_if_from(vars,from,src='set_vars_if_from')
        if vars.class != Hash
          raise "The first ('vars') argument to set_vars_if_from() must be a hash."
        end
        erb_trace("set_vars_if_from(#{vars},'#{from}','#{src}') =>")
        @erb_trace_indent.push('  ')
        vars.each { |var,val| set_var_if_from(var,val,from,src) }
        @erb_trace_indent.pop()
      end
      #------------------------------------------------------------------------#
      # Sets the @var variable if its either undefined. or its source does not #
      # match the @from regex.                                                 #
      #------------------------------------------------------------------------#
      def set_var_if_not_from(var,val,from,src='set_var_if_not_from')
        erb_trace("set_var_if_not_from('#{var}','#{val}','#{from}','#{src}')")
        set_var(var,val,src) if not @vars.key?(var) or @vars[var][:src] !~ /#{from}/
      end
      #------------------------------------------------------------------------#
      # Sets all variables in the @vars hash that are either undefined, or     #
      # have sources not matching the @from regex.                             #
      #------------------------------------------------------------------------#
      def set_vars_if_not_from(vars,from,src='set_vars_if_not_from')
        if vars.class != Hash
          raise "The first ('vars') argument to set_vars_if_not_from() must be a hash."
        end
        erb_trace("set_vars_if_not_from(#{vars},'#{from}','#{src}') =>")
        @erb_trace_indent.push('  ')
        vars.each do |var,val|
          set_var(var,val,src) if not @vars.key?(var) or @vars[var][:src] !~ /#{from}/
        end
        @erb_trace_indent.pop()
      end
      #------------------------------------------------------------------------#
      # Deletes the @var variable.                                             #
      #------------------------------------------------------------------------#
      def del_var(var)
        if @vars.key?(var)
          erb_trace("del_var('#{var}') => '#{@vars[var][:val]}' (set from #{@vars[var][:src]})")
          @vars.delete(var)
        else
          erb_trace("del_var('#{var}') => <noop, undefined variable>")
        end
      end
      alias_method(:d,:del_var)
      #------------------------------------------------------------------------#
      # Deletes all variables in the @vars array.                              #
      #------------------------------------------------------------------------#
      def del_vars(vars)
        if vars.class != Array
          raise "The first ('vars') argument to del_vars() must be an array."
        end
        erb_trace("del_vars(['#{vars.join("','")}']) =>")
        @erb_trace_indent.push('  ')
        vars.each { |var| del_var(var) }
        @erb_trace_indent.pop()
      end
      #------------------------------------------------------------------------#
      # Deletes the @var variable if its source matches the @from regex.       #
      #------------------------------------------------------------------------#
      def del_var_if_from(var,from)
        erb_trace("del_var_if_from('#{var}','#{from}')")
        del_var(var) if @vars.key?(var) and @vars[var][:src] =~ /#{from}/
      end
      #------------------------------------------------------------------------#
      # Deletes all variables in the @vars array with sources matching the     #
      # @from regex.                                                           #
      #------------------------------------------------------------------------#
      def del_vars_if_from(vars,from)
        if vars.class != Array
          raise "The first ('vars') argument to del_vars_if_from() must be an array."
        end
        erb_trace("del_vars_if_from(['#{vars.join("','")}'],'#{from}') =>")
        @erb_trace_indent.push('  ')
        vars.each do |var|
          del_var(var) if @vars.key?(var) and @vars[var][:src] =~ /#{from}/
        end
        @erb_trace_indent.pop()
      end
      #------------------------------------------------------------------------#
      # Deletes all variables with sources matching the @from regex.           #
      #------------------------------------------------------------------------#
      def del_all_vars_from(from)
        erb_trace("del_all_vars_from('#{from}') =>")
        @erb_trace_indent.push('  ')
        @vars.each do |var,meta|
          del_var(var) if meta[:src] =~ /#{from}/
        end
        @erb_trace_indent.pop()
      end
      #------------------------------------------------------------------------#
      # Deletes the @var variable if its src does not match the @from regex.   #
      #------------------------------------------------------------------------#
      def del_var_if_not_from(var,from)
        erb_trace("del_var_if_not_from('#{var}','#{from}')")
        del_var(var) if not @vars.key?(var) or @vars[var][:src] !~ /#{from}/
      end
      #------------------------------------------------------------------------#
      # Deletes all variables in the @vars array with sources not matching the #
      # @from regex.                                                           #
      #------------------------------------------------------------------------#
      def del_vars_if_not_from(vars,from)
        if vars.class != Array
          raise "The first ('vars') argument to del_vars_if_not_from() must be an array."
        end
        erb_trace("del_vars_if_not_from(['#{vars.join("','")}'],'#{from}') =>")
        @erb_trace_indent.push('  ')
        vars.each do |var|
          del_var(var) if not @vars.key?(var) or @vars[var][:src] !~ /#{from}/
        end
        @erb_trace_indent.pop()
      end
      #------------------------------------------------------------------------#
      # Deletes all variables with sources not matching the @from regex.       #
      #------------------------------------------------------------------------#
      def del_all_vars_not_from(from)
        erb_trace("del_all_vars_not_from('#{from}') =>")
        @erb_trace_indent.push('  ')
        @vars.each do |var,meta|
          del_var(var) if meta[:src] !~ /#{from}/
        end
        @erb_trace_indent.pop()
      end
    end
    RenderContext.untrust # needed for SAFE_LEVEL=4 to work
    #==========================================================================#
    #
    #
    #
    def self.cli_app
      begin
      app = File.basename($0)
      (op = OptionParser.new do |p|
        p.banner =
          "Usage:\n" +
          "  #{app} [options] < template-and-vars.yml  # template and vars as single yaml stream on stdin\n" +
          "  #{app} [options] < template.erb           # template and vars as single yaml stream on stdin\n" +
          "  #{app} [options] template-and-vars.yml    # template and vars in one (yaml) file\n" +
          "  #{app} [options] template.erb vars.yml    # template and vars in separate files\n" +
          "  #{app} [options] template < vars      # template in file, vars on srtdin\n" +
          "Options:"
        p.on("-t TMPL","Variable overrides. VARS is a YAML file or string containing a var=>val hash.") {}
        p.on("-v VARS","Variable overrides. VARS is a YAML file or string containing a var=>val hash.") {}
        p.on("-d VARS","Variable defaults. VARS is a YAML file or string containing a var=>val hash.") {}
        p.on("-p",".") {}
        p.on("-m",".") {}
        p.on("-h","Display this help message and exit.") { puts(p.help); exit(0) }
      end).parse!
      end
      vars = {}
      vars = build_vars(vars,'erbt-cli')
      begin
        rctx = RenderContext.new(File.read(ARGV[0]),ARGV[0],vars)
      rescue e
        puts "#{e.to_s.split("\n")[0..4].join("\n")}"
        exit -1
      end
      puts rctx.render()
    end
  end
end
Loosbrock::ErbT::cli_app if $0 == __FILE__
