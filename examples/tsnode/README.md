# tsnode

A headless command-line node built on `package:libtailscale`'s public API. It
is the reference integration for the package and a handy way to test a
control server: every command starts a node from the shared options, waits
until it is `Running`, does its job and shuts the node down again.

```
tsnode join   --control-url https://headscale.example.com --auth-key tskey-… \
              --hostname demo-a --state-dir ./state-a --ephemeral
tsnode join   --oauth-client-id k… --oauth-client-secret tskey-client-… --tag tag:demo
tsnode info   [--json]           # this node: names, addresses, tailnet, state
tsnode peers  [--json]           # name, IPs, online, OS, tags, last seen, owner
tsnode echo   --port 7777        # echo/chat listener, prints incoming lines
tsnode send   demo-b 7777 "hi"   # dial a peer by MagicDNS name or IP, print the reply
tsnode send   --fd 100.64.0.2 7777 "hi"   # same over the fd path instead of SOCKS5
tsnode fetch  http://demo-b:8080/health [--body] [--insecure]
```

Shared options: `--control-url` (default Tailscale), `--auth-key`
(`$TS_AUTHKEY`), `--oauth-client-id` + `--oauth-client-secret`
(`$TS_OAUTH_CLIENT_SECRET`) + `--tag`, `--interactive`, `--hostname`,
`--state-dir` (default `~/.tsnode/<hostname>`), `--ephemeral`, `--timeout`,
`--verbose`. Without a key and without `--interactive` the node reuses the
identity stored in `--state-dir`.

State transitions, login URLs and health problems go to stderr; results go to
stdout. `tsnode` configures the build hook in its own `pubspec.yaml`
(`build_from_source: true`), like any application would. The Flutter
counterpart, with the same chat protocol, lives in
[`../node_console`](../node_console).

## Trying it without an account

The parent package can build upstream's in-process test control server. In the
repository root:

```sh
echo '{"build_from_source": true, "build_test_control": true}' > hook/local_config.json
dart run tool/test_control_server.dart        # prints http://127.0.0.1:<port>
```

Then, from `examples/tsnode/`, with that URL (the test server approves every node, so
`--interactive` completes on its own):

```sh
dart run bin/tsnode.dart echo --control-url $URL --interactive --hostname echo-a --state-dir /tmp/a
dart run bin/tsnode.dart send --control-url $URL --interactive --hostname send-b --state-dir /tmp/b <ip of echo-a> 7777 "hello"
dart run bin/tsnode.dart peers --control-url $URL --interactive --hostname send-b --state-dir /tmp/b
```

## Headscale

```sh
headscale users create demo
headscale preauthkeys create --user demo --reusable --ephemeral
dart run bin/tsnode.dart join --control-url https://hs.example.com --auth-key <key> --hostname demo-a --ephemeral
```

For the interactive flow, run `join --interactive`; the printed URL ends in the
registration id an admin passes to Headscale (0.29 and later):

```sh
headscale auth register --auth-id hskey-authreq-… --user demo
```

Older Headscale versions use `headscale nodes register --user demo --key mkey:…`.

## Tailscale

```sh
TS_AUTHKEY=tskey-auth-… dart run bin/tsnode.dart join --hostname demo-a
dart run bin/tsnode.dart join --oauth-client-id k… --oauth-client-secret tskey-client-… --tag tag:demo --ephemeral
```
