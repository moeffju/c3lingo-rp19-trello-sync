# First run

1. Install the required gems with `bundle install`

2. Get your Trello keys and tokens: Run `irb -rubygems`, then:

```
require 'trello'
Trello.open_public_key_url   # this gives you your api key
Trello.open_authorization_url key: 'YOUR_API_KEY_HERE'   # this gives you your member token
```

3. Copy `config.toml.sample` to `config.toml` and edit it, fill in your `developer_key` and `member_token`

# Dry run

Run `./sync.rb --dry-run`. This will only prepare the board (creating the lists) but not create or update any cards.

# Test run

Run `./sync.rb`. By default, this modifies a test board.

# Production run

Run `./sync.rb --prod`. You probably do not want to do this.
