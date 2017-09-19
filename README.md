# gh-shorthand-backend

This is an RPC server used by the [`gh-shorthand`](https://github.com/zerowidth/gh-shorthand) script for retrieving data from the GitHub API in support of an [Alfred workflow](https://github.com/zerowidth/gh-shorthand.alfredworkflow).

## Installation

* Clone this repository
* Configure a `socket_path` and `api_token` in `~/.gh-shorthand.yml`: the `socket_path` should be the default `/tmp/gh-shorthand.sock`, and `api_token` should be a GitHub API token you've [generated for your account](https://github.com/settings/tokens).
* `ruby server.rb`

This was written using Ruby 2.4. Ruby 2.0 won't work, but anything newer should.

## Design

The RPC server is designed to return a result as quickly as possible to prevent the calling `gh-shorthand` script from blocking and preventing the Alfred UI from updating. Since most queries aren't fast, the usual response will be "PENDING", letting the Alfred script filter know it should retry. It's using ruby threads to issue GraphQL queries in the background, and once a query has returned, a local cache keeps the results for a short period of time.

## Protocol

An RPC query is a specific keyword followed by one or more arguments. The response will be one of:

* `OK`, followed by the results, one on each line.
* `PENDING`
* `ERROR`, followed by an error message on a new line.

The socket is closed after the response is complete.

Queries:

* `repo:owner/name` retrieves the title of the `owner/name` repository.
* `issue:owner/name#123` retrieves the type (issue or PR), state (open/closed), and title of issue 123 in the `owner/name` repository.
* `repo_project:owner/name/123` retrieves the state (open/closed) and title of the given project in a repository.
* `repo_projects:owner/name` retrieves a list of state and title for projects in a repository
* `org_project:login/123` retrieves the state and title of the given project in an organization.
* `org_projects:login` retrieves a list of state and title for projects in an organization.
* `issuesearch:query` searches for issues in GitHub, returning a list of matching issues with owner/name, issue number, type, state, and title.

## Debugging

Use `-v` or `--verbose` for verbose logging.

To talk to the socket from the console, try one of

* `socat - UNIX-CONNECT:/tmp/gh-shorthand.sock`
* `nc -U /tmp/gh-shorthand.sock`

## Contributing

Open an issue or PR. Any changes here will likely need to be accompanied by changes in the calling process, [`gh-shorthand`](https://github.com/zerowidth/gh-shorthand).