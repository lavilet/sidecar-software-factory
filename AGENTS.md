# Agent instructions

To install this factory for another checkout, follow [the setup brief](docs/agent-setup.md). To work on the engine itself, run `bin/smoke` from this repository with Ruby 3.2+ and Python 3.9+.

Keep target-specific paths, commands, data and architecture in its external profile. Treat the target checkout as the source of truth for development and CI. Put portable defaults in `templates/profile/`. Keep runtime state, credentials, user home paths and generated evidence outside source control.

For the issue, epic and dashboard regression suite, install RSpec 3.13 (`gem install rspec -v "~> 3.13"`) and run `rspec spec`. These tests use in-memory GitHub fixtures.
