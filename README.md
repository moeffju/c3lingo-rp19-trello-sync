# First run

1. Install the required gems with `bundle install`

2. Get your Trello keys and tokens: Run `irb -rubygems`, then:

```
require 'trello'
Trello.open_public_key_url   # this gives you your api key
Trello.open_authorization_url key: 'YOUR_API_KEY_HERE'   # this gives you your member token
```

3. Copy `config.toml.sample` to `config.toml` and edit it, fill in your `developer_key` and `member_token`

# Test run

Create a Trello board for testing, get its ID (from irb as above, run `Trello::Board.all` to get all your boards; you want the `id` field.)

Change `BOARD_ID = 'xxx'` in line 22 to your test board ID.

Run `./sync.rb`.

# Production run

Revert to the old `BOARD_ID` and run `./sync.rb`.
