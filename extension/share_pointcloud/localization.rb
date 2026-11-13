# encoding: UTF-8
module SHARE3DCAM
  module PointCloud
    module Locale
      # Keep one checked-in UTF-8 phrase table for the HtmlDialog and Ruby tools.
      source=File.read(File.join(__dir__,'translations.js'),encoding:'UTF-8').strip
      EN=JSON.parse(source.delete_prefix('globalThis.SHARE_TRANSLATIONS = ').delete_suffix(';')).freeze
      PATTERNS=EN.filter_map do |key,value|
        next unless key.match?(/\{\d+\}/)
        indices=[]
        expression=key.split(/(\{\d+\})/).map do |part|
          if part.match?(/\A\{\d+\}\z/)
            indices<<part[1..-2].to_i
            '(.*?)'
          else
            Regexp.escape(part)
          end
        end.join
        [Regexp.new("\\A#{expression}\\z",Regexp::MULTILINE),value,indices]
      end.freeze

      def self.text(value,language,depth=0)
        text=value.to_s
        return text unless language=='en'
        return EN[text] if EN.key?(text)
        if depth<4
          PATTERNS.each do |pattern,target,indices|
            match=pattern.match(text)
            next unless match
            values={}
            indices.each_with_index {|index,i| values[index]=self.text(match[i+1],language,depth+1)}
            return target.gsub(/\{(\d+)\}/) {|token| values.fetch(Regexp.last_match(1).to_i,token)}
          end
        end
        text
      end
    end

    def self.language
      Sketchup.read_default(DICT,'language','zh-CN')=='en' ? 'en' : 'zh-CN'
    end

    def self.tr(text)
      Locale.text(text,language)
    end

    def self.set_language(value)
      raise ArgumentError,'Unsupported language' unless %w[zh-CN en].include?(value)
      Sketchup.write_default(DICT,'language',value)
      active=Sketchup.active_model.tools.active_tool
      if active && active==@localized_status_tool
        Sketchup.set_status_text(tr(@localized_status_source)) if @localized_status_source
        Sketchup.vcb_label=tr(@localized_vcb_source) if @localized_vcb_source
      end
      @toolbar_command.tooltip=tr('导入点云、裁剪切片与捕捉描图') if @toolbar_command
    end

    def self.status(text)
      @localized_status_source=text
      @localized_status_tool=Sketchup.active_model.tools.active_tool
      Sketchup.set_status_text(tr(text))
    end

    def self.vcb_label(text)
      @localized_vcb_source=text
      Sketchup.vcb_label=tr(text)
    end

    def self.messagebox(text,*args)
      UI.messagebox(tr(text),*args)
    end

    def self.inputbox(prompts,defaults,title)
      UI.inputbox(prompts.map {|text| tr(text)},defaults,tr(title))
    end

    def self.openpanel(title,directory,filter)
      UI.openpanel(tr(title),directory,tr(filter))
    end

    def self.savepanel(title,directory,filename)
      UI.savepanel(tr(title),directory,filename)
    end

    def self.select_directory(**options)
      UI.select_directory(**options.merge(title:tr(options[:title])))
    end
  end
end
