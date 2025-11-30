# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'generators/ruby_llm/upgrade_to_v2_0/upgrade_to_v2_0_generator'
require_relative '../../support/generator_test_helpers'

RSpec.describe RubyLLM::Generators::UpgradeToV20Generator, :generator, type: :generator do
  include GeneratorTestHelpers

  describe 'generator definition' do
    it 'has the correct namespace' do
      expect(described_class.namespace).to eq('ruby_llm:upgrade_to_v2_0')
    end

    it 'has a source root defined' do
      expect(described_class.source_root).to include('templates')
    end

    it 'accepts message model mapping argument' do
      arguments = described_class.arguments
      expect(arguments.map(&:name)).to include('model_mappings')
    end
  end

  describe 'migration template' do
    let(:template_path) { File.join(described_class.source_root, 'add_thinking_to_messages.rb.tt') }

    it 'exists' do
      expect(File.exist?(template_path)).to be true
    end

    it 'adds thinking column' do
      template_content = File.read(template_path)
      expect(template_content).to include('add_column')
      expect(template_content).to include(':thinking')
      expect(template_content).to include(':json')
    end

    it 'checks for existing column' do
      template_content = File.read(template_path)
      expect(template_content).to include('column_exists?')
    end
  end
end
