# frozen_string_literal: true

require 'rake'
require 'rake/notes/rake_task'

require 'rspec/core'
require 'rspec/core/rake_task'

require 'rubocop/rake_task'

#
# rake notes:custom to read various code notes
ENV['ANNOTATION'] = 'CODE_NOTES'

RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = ' --format documentation '
end

RuboCop::RakeTask.new(:rubocop) do |t|
  t.options = ['--auto-correct', '--display-cop-names', '--config=.rubocop.yml']
  t.fail_on_error = false
end

task default: %i[rubocop spec]
