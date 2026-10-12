このフォルダには秘密鍵を置きます（git には絶対にコミットしないでください。`.gitignore` 済み）。

- `AuthKey_XXXXXXXXXX.p8` : Apple の APNs Auth Key（着信プッシュを使う場合のみ）

HTTPS の証明書は Caddy が自動取得・更新するので、ここに置く必要はありません。
