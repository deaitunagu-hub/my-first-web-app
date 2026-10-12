# KidsCall — 家族だけのビデオ通話 iPhone アプリ

子どもとスマホでビデオ通話するためだけの、招待制・最大5台のアプリです。

- **できること**: グループ内の家族と1対1〜最大5台でビデオ通話する。それだけです。
- **できないこと（意図的）**: チャット、連絡先検索、公開ルーム、アカウント登録、広告、分析。すべて無し。
- **秘匿性**: サーバーにはグループが **1つしか** 作れません。管理者（最初の1台）が作る **10分で失効する1回限りの招待QR** を直接読み取った端末以外は、どうやっても入れません。通話の映像・音声は端末同士で暗号化（DTLS-SRTP）され、サーバーは中継しません。

```
ios/KidsCall/       iPhone アプリ (SwiftUI + WebRTC + CallKit/PushKit)
server/             招待制グループ管理 + シグナリングサーバー (Node.js, 依存は ws のみ)
docker-compose.yml  サーバー + coturn(TURN) をまとめて起動
index.html          (既存の GitHub Pages ページ。アプリとは無関係)
```

---

## 1. 仕組みと秘匿性の設計

| 要素 | 設計 |
|---|---|
| グループ数 | サーバー1台につき **1つだけ**。作成後は `SETUP_TOKEN` を消して新規作成を永久に無効化 |
| メンバー上限 | **5台**。サーバー側で強制（6台目は招待の発行自体ができない） |
| 端末の認証 | 各端末が初回起動時に **Ed25519 鍵ペア** を生成し、秘密鍵は iPhone の Keychain（この端末のみ・バックアップ不可）に保存。パスワードもアカウントも無い |
| 参加方法 | 管理者端末が発行する招待（80bit の乱数、**10分で失効・1回限り・常に1件だけ有効**）を QR で読み取る。招待トークンはサーバーにハッシュのみ保存 |
| 接続 | WebSocket 接続のたびにサーバーのナンスへ署名して本人確認。登録外の鍵は即切断 |
| 映像・音声 | WebRTC の **P2P フルメッシュ**（5台なら各端末が最大4本の接続）。DTLS-SRTP で端末間暗号化。サーバーは SDP/ICE を転送するだけで映像を一切見ない |
| NAT 越え | 自前の coturn。TURN の認証は12時間で失効する HMAC クレデンシャルで、アプリに固定パスワードは入らない。TURN が中継するのも暗号化済みパケットのみ |
| 着信 | APNs **VoIP プッシュ**で、アプリを閉じていても iPhone 標準の着信画面が鳴る。プッシュの中身は「発信者の表示名」と通話IDだけ |
| 通話履歴 | CallKit の `includesCallsInRecents = false`。iPhone の「電話」アプリの履歴に残らない |
| 端末の削除 | 管理者がいつでも外せる（紛失時など）。外された端末は鍵ごと無効化され、再招待なしでは二度と入れない |

### 通話の流れ

1. 誰かが「みんなに電話する」を押す → サーバーの通話に参加（その時点で通話が空なら他の全端末に VoIP プッシュ）
2. 相手が着信画面で応答 → 自分も通話に参加
3. 後から入った端末が、先にいる端末それぞれに WebRTC のオファーを送り、P2P 接続を張る
4. 全員が切ると通話は消える

---

## 2. サーバーのセットアップ

必要なもの: Linux サーバー1台（月数百円の VPS で可）、ドメイン名（サブドメインで可）、Docker。

1. ドメインの DNS で **A レコード**をサーバーのグローバル IP に向ける（例: `call.example.com`）。
2. サーバーのファイアウォールで `80/tcp`, `443/tcp`, `3478/udp`, `3478/tcp`, `49160-49200/udp` を開ける。
3. サーバーで次を実行:

```bash
git clone https://github.com/deaitunagu-hub/my-first-web-app.git
cd my-first-web-app
./scripts/setup.sh
```

スクリプトがドメイン名を聞き、秘密鍵（`SETUP_TOKEN`, `TURN_SECRET`）を自動生成して `server/.env` に書き、Caddy（HTTPS 自動取得）+ シグナリングサーバー + coturn を起動します。最後に **アプリに入力するサーバー URL と合言葉** が表示されます。

- HTTPS 証明書は Caddy が Let's Encrypt から自動取得・更新します。手動設定は不要です。
- 動作確認: `curl https://<ドメイン>/v1/health` が `{"ok":true,...}` を返せば OK。
- 開発時は Docker を使わず `cd server && npm install && npm start` でも動きます（`node >= 20`）。

### グループを作った後

最初の1台を登録し終えたら、`server/.env` の `SETUP_TOKEN=` を空にして `docker compose restart signaling` してください。以後このサーバーでは **誰もグループを作れません**（既存グループへの招待は管理者からのみ可能）。

### 初期化したいとき

`docker compose down && docker volume rm my-first-web-app_signaling-data` で全メンバーが消えます。`./scripts/setup.sh` を再実行すると新しい `SETUP_TOKEN` が表示されるので、最初の1台から登録し直します。

### サーバーのテスト

```bash
cd server && npm test
```

招待の1回限り・10分失効・5台上限・署名検証・非メンバー拒否・削除時の即切断などを自動テストしています。GitHub Actions でも `server/` の変更時に自動実行されます。

---

## 3. iPhone アプリのビルド

必要なもの: Mac + Xcode 15 以上、Apple Developer Program（VoIP プッシュと実機配布に必要）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
brew install xcodegen
cd ios/KidsCall
xcodegen generate
open KidsCall.xcodeproj
```

Xcode で:

1. **Signing & Capabilities** で自分の Team を選び、Bundle Identifier を自分のもの（例 `com.yourname.kidscall`）に変更。
2. Capabilities に **Push Notifications** と **Background Modes (Voice over IP, Audio)** が付いていることを確認（project.yml で設定済み）。
3. 実機を選んで Run。

Swift Package として [stasel/WebRTC](https://github.com/stasel/WebRTC)（Google WebRTC のバイナリ配布）を使います。初回は Xcode が自動で取得します。

### VoIP プッシュ（着信）の設定

1. [Apple Developer](https://developer.apple.com/account/resources/authkeys/list) で **Key** を作成し、*Apple Push Notifications service (APNs)* を有効にして `.p8` をダウンロード。
2. `.p8` を `secrets/` に置き、`server/.env` の `APNS_*` 行のコメント（先頭の `#`）を外して `APNS_KEY_PATH / APNS_KEY_ID / APNS_TEAM_ID / APNS_BUNDLE_ID` を設定し、`docker compose restart signaling`。
3. Xcode から直接インストールしたビルドは `APNS_ENV=sandbox`、TestFlight / App Store 配布は `APNS_ENV=production`。
4. 本番配布なら `project.yml` の `aps-environment` を `production` に。

設定しなくても動きますが、その場合「アプリを開いている端末しか着信に気づけない」状態になります。

### 家族への配布

App Store に出さず家族だけに配るなら **TestFlight**（最大100台の内部/外部テスト）が簡単です。Ad Hoc 配布でも構いません。

---

## 4. 使い方

### 管理者（親のスマホ・最初の1台）

1. アプリを開き「最初の1台として設定する（管理者）」をタップ。
2. サーバー URL、`SETUP_TOKEN`、グループ名、自分の名前を入力して作成。
3. ホーム画面の「新しい端末を招待する」で QR を表示。**相手の端末で直接読み取ってもらいます**（10分以内・1回だけ）。

### 子どものスマホ（2台目以降）

1. アプリを開き「招待QRコードを読み取る」。
2. 自分の名前を入れて「グループに参加する」。以後、何も設定することはありません。

### 通話

- ホーム画面の大きな緑のボタンを押すだけ。誰かが通話中なら「通話に参加する」に変わります。
- 相手には iPhone 標準の着信画面が出ます。
- 通話中はマイク / カメラ オン・オフ、前後カメラ切替、終了のみ。

### 端末を外す

管理者のホーム画面でメンバーを左にスワイプ → 「外す」。スマホを紛失したときなどに。外した端末は即座に切断され、再招待しないと戻れません。

---

## 5. 制限事項・注意

- **Android は対象外**（要件どおり iPhone のみ）。
- P2P フルメッシュのため、5台同時だと各端末が4本分の映像を送受信します。モバイル回線では解像度を 640px / 24fps 程度に抑えています。それでも厳しい場合は Wi-Fi を推奨します。
- サーバーの管理者は「誰がいつ通話に参加したか」は分かりますが、映像・音声は一切見られません。
- このリポジトリには Xcode のビルド環境が無いため、**iOS 側のコードは実機ビルドでの最終確認が必要**です。サーバー側は自動テスト済みです。
- 本アプリは暗号化通信を使いますが、Apple 標準の暗号（TLS/DTLS-SRTP）のみのため輸出規制の申告は不要（`ITSAppUsesNonExemptEncryption = false`）です。
