# SnipReel

メニューバーに常駐する macOS 用の範囲キャプチャ・画面録画アプリ(macOS 15 以降)。

## ビルドと起動

```sh
./scripts/build-app.sh      # build/SnipReel.app を作成
open build/SnipReel.app
```

初回は「画面収録」の許可を求められます(録画でマイクを使う場合は「マイク」の許可も)。システム設定 →「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」で SnipReel を許可し、アプリを再起動してください。

## 使い方

| 操作 | 内容 |
|---|---|
| `⇧⌘2`(設定で変更可) | 範囲選択を開始。ドラッグで選択、`Esc` / 右クリックでキャンセル |
| 選択完了 | キャプチャが最前面に表示され、クリップボードにコピーされる |
| 左ドラッグ | キャプチャを移動 |
| 四隅をドラッグ | 縦横比を保ったまま拡大・縮小(100% 付近で吸着、最大 400%)。保存・コピーにも反映 |
| `Ctrl` + 右ドラッグ | 鉛筆で書き込み |
| 右クリック(または Ctrl+左クリック) | メニュー(コピー / 保存 / 取り消し / 色 / 太さ / 閉じる) |
| `⌘C` | 書き込み込みでコピー |
| `⌘S` | 保存ダイアログを開いて PNG で保存 |
| `⌘Z` / `⇧⌘Z` | 書き込みの取り消し / やり直し |
| `Esc` / `⌘W` | キャプチャを閉じる |

### 上部の帯

| 項目 | 内容 |
|---|---|
| ⓧ | 閉じる |
| `1280 × 720 px` | 出力される画像のピクセル数 |
| `245 KB` | 現在の設定で保存した時のファイルサイズ(書き込み・サイズ・形式の変更で自動更新) |
| サイズ | 100 / 75 / 50 / 33 / 25%、または「サイズを指定…」で幅・高さを px 指定(縦横比固定)。表示も同じ倍率で縮む |
| 形式 | PNG(劣化なし)/ JPEG 高・中・低画質。JPEG にするとファイルサイズが小さくなる。選んだ形式は次回も使われる |
| コピー / 保存ボタン | `⌘C` / `⌘S` と同じ。サイズ・形式の設定が反映される |

帯の空いている所をドラッグしてもウインドウを移動できます。

## 画面録画

| 操作 | 内容 |
|---|---|
| `⌥⇧⌘2`(設定で変更可) | 録画範囲の選択を開始。ドラッグで範囲、クリックで画面全体、`Esc` でキャンセル |
| カウントダウン | 3 秒後に録画開始。範囲の周りに赤い枠が出る(枠・操作バーは動画に写らない) |
| 操作バー | 経過時間 / システム音声のオン・オフ / マイクのオン・オフ / 一時停止・再開 / 停止 |
| 停止 | 操作バーの ■、もう一度ショートカット、またはメニューバーのアイコン(録画中は赤い ● と経過時間)をクリック |
| 停止後 | プレビューが最前面に表示される。帯に長さ・解像度・ファイルサイズ。`⌘S` で MP4 を保存、`⌘C` でファイルをコピー(Finder や Slack に貼り付け可)、`Esc` で閉じる(未保存なら確認) |

- 音声: システム音声(Mac から出る音)とマイクを個別にオン・オフでき、両方オンなら 1 本の音声にミックスされます。設定は次回も引き継がれます
- 録画中に一時停止したり音声の設定を変えたりしても、最後に 1 本の MP4 につながります
- 一時ファイルは `~/Library/Caches/io.github.shumity-lab.SnipReel/Recordings` に置かれ、1 日以上経ったものは次回起動時に削除されます

## メニューバー

メニューバーのアイコンから「範囲をキャプチャ」「画面を録画」「すべてのキャプチャを閉じる」「設定…」「終了」を操作できます。

## 構成

- `AppDelegate.swift` — メニューバー常駐、キャプチャの流れ
- `HotKeyManager.swift` / `Shortcut.swift` — グローバルショートカット(Carbon)
- `SelectionOverlay.swift` — 範囲選択オーバーレイ
- `ScreenCapturer.swift` — ScreenCaptureKit による撮影
- `ScreenRecorder.swift` — 録画(セグメント分割)と 1 本の MP4 への結合・音声ミックス
- `RecordingUI.swift` — 録画枠・カウントダウン・操作バー
- `VideoWindow.swift` — 録画後のプレビュー
- `CaptureWindow.swift` — 最前面表示・鉛筆書き込み・保存・コピー
- `InfoBarView.swift` — 上部の帯
- `OutputSettings.swift` — 出力形式と縮小・エンコード
- `PenSettings.swift` — 鉛筆の色・太さ
- `SettingsWindow.swift` — 設定画面(ショートカット変更)

## アイコン

`Resources/AppIcon-source.png`(白背景の元画像)から `Resources/AppIcon.icns` を生成しています。元画像を差し替えたら次を実行してください。

```sh
swift scripts/make-icon.swift Resources/AppIcon-source.png Resources/AppIcon.icns
```

メニューバーのアイコンは `Resources/MenuBarIcon-source.png`(暗い背景に白い線)から生成しています。

```sh
swift scripts/make-menubar-icon.swift Resources/MenuBarIcon-source.png Resources
```

## 配布用ビルド(メンテナー向け)

Developer ID Application 証明書が必要です。初回のみ、公証用の認証情報をキーチェーンに保存します。

```sh
xcrun notarytool store-credentials snipreel-notary \
  --apple-id <Apple ID> --team-id <チームID> --password <アプリ用パスワード>
```

その後、次のコマンドで `build/SnipReel-<バージョン>.dmg` が作られます(Apple シリコン / Intel 両対応、公証済み)。

```sh
./scripts/release.sh
```

バージョンは `Resources/Info.plist` の `CFBundleShortVersionString` で管理しています。

## 多言語対応

英語・日本語に対応しています。表示言語は macOS の言語設定に従います(システム設定 →「一般」→「言語と地域」→「アプリケーション」でアプリごとに変更も可)。

- コード中の文言は `L("English text")` で書く(英語がキー)
- 日本語訳は `scripts/strings_ja.py` に追加する
- `Resources/*.lproj/*.strings` はビルド時に `scripts/gen-strings.py` が自動生成する(未翻訳があるとビルドが止まる)
