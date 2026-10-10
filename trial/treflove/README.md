# The Treflove trial (task 009)

Draft: the teardown sequence below is written by hand from
`docs/02-semantics.md`, "Cascading death", before the trial first runs
(test case 1 of `tasks/009-treflove-trial.md`). `run.lua` compares the
log with it.

## The teardown

`destroy(connection)` in `ConnectionManager:remove`, on the client, after a
login. The log is one line per destructor body (`release()`, or
"destroyed" for a class without one), indented under the call that made
it; a line starting with `>` is the statement that runs next.

```
> client: connection_manager:remove(connection)
Connection:release(destroy)
Session destroyed (anchor)
UserMenuScreen:release(anchor)
  back stack depth 0
DownloadMissingAssetsRp:release(anchor)
  Connection:unregister_request_handler(DownloadMissingAssetsRp)
DownloadAssetRp:release(anchor)
  Connection:unregister_request_handler(DownloadAssetRp)
UploadAssetRp:release(anchor)
  Connection:unregister_request_handler(UploadAssetRp)
GameDataRp:release(anchor)
  Connection:unregister_request_handler(GameDataRp)
Login:release(anchor)
  LoginRp:release()
    Connection:unregister_request_handler(LoginRp)
  LogoutRp:release()
    Connection:unregister_request_handler(LogoutRp)
LogoutRp:release(anchor)
  Connection:unregister_request_handler(LogoutRp)
LoginRp:release(anchor)
  Connection:unregister_request_handler(LoginRp)
```
