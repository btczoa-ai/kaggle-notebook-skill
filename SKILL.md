---
name: kaggle-notebook
description: Kaggle GPU (T4 x2 / 32GB VRAM) 環境上で `kaggle` CLI (`kaggle kernels push`) を用いて大規模 GGUF LLM 推論サーバー（FastAPI + llama-cpp-python + Cloudflare Tunnel）をデプロイ・起動・検証するための専用スキル。
---

# Kaggle LLM Studio Deployment & Operations Standards

Kaggle 環境（`/kaggle/working`）で `kaggle kernels push` により大規模 GGUF LLM 推論サーバーを自動デプロイ・起動・検証する際の標準規約とベストプラクティスです。

---

## 1. `/tmp/` 配下への作業・重量物分離 (`VENV_DIR`, `MODELS_DIR`)
- `/kaggle/working` に `.venv` や大容量モデル（20GB+）を置くと、Kaggle の出力保存制限（20GB / ファイル数上限）や `kaggle kernels output` 時の大量ファイルダウンロード停滞を招く。
- `.env` で `VENV_DIR=/tmp/.venv`、`MODELS_DIR=/tmp/models` を定義し、`/kaggle/working` には軽量なソースコードと `logs/` のみを残す。

## 2. CUDA プリビルド wheel (`llama-cpp-python[server]`) の採用（厳守）
- 推論バックエンドとして `llama.cpp` を利用する場合、`llama-cpp-python[server]` は**ソースコンパイルを行わず、必ず公式の CUDA 対応プリビルドバイナリ（wheel）**を使用してインストールすること。
- Kaggle コンテナでは CMake が `CUDA::cuda_driver` を見つけられず `llama.cpp` ソースビルドが失敗しやすい（また `-j` 無制限は RAM 不足で `Error 137` を起こす）。
- `--extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cu124` でプリビルド wheel を導入し、`nvidia-cuda-runtime-cu12` と `nvidia-cublas-cu12` を同時インストールする。
- サブプロセス起動時に `LD_LIBRARY_PATH` へ `/tmp/.venv/lib/python*/site-packages/nvidia/*/lib` および `/usr/local/cuda/lib64` を追加し、`libcudart.so.12` 欠落エラーを防止する。

### 2.1. 公式 `llama.cpp` ネイティブバイナリ（Ubuntu x64 CUDA 13）の直接利用
- Python 3.13 + CUDA 13.0 等の最新 Kaggle 環境で `llama-cpp-python` の適合 wheel が無い場合や、`llama-server` / `llama-cli` を直接起動する場合は、**`ggml-org/llama.cpp` 公式 GitHub Releases から最新の Ubuntu x64 CUDA 13 プリコンパイル済みバイナリを取得**し、`/opt/llama.cpp` へ展開して `/etc/ld.so.conf.d/` 登録＋`/usr/local/bin/` へシンボリックリンクを作成すること（ソースビルド禁止）。
- 参考テンプレート: `scripts/install_llama_cpp.sh`

## 3. Hugging Face API による実 GGUF ファイル名の事前検証
- リポジトリ上のファイル名は短縮形になっていることが多いため、`https://huggingface.co/api/models/<repo>/tree/main` で実ファイル名を事前確認し、404 エラーを防ぐ。

## 4. ポート統合 (`TUNNEL_PORT` + 内部 `TUNNEL_PORT + 1`)
- `.env` には `TUNNEL_PORT` のみを定義し、内部推論サーバーポートは `TUNNEL_PORT + 1` を自動割り当てする。

## 5. バッチ実行 (`kaggle kernels push`) 向けの `.env` 注入と終了設計
- `kaggle kernels push` での自動実行では事前ファイルアップロードができないため、先頭セルに `%%writefile .env` を配置する。
- 最終セルに `while True:` の無限ログ監視を置くとタイムアウトまで完了しないため、スナップショット表示に置き換えて正常終了（`KernelWorkerStatus.COMPLETE`）させる。

## 6. 環境バージョン情報の事前ログ出力規約（厳守）
- **ノートブック開始直後の環境ダンプ**: 本格的なインストールや推論処理を開始する前の最初の段階で、**OS (`cat /etc/os-release` / `uname -a`)、Python (`python3 --version`)、CUDA / GPU (`nvidia-smi` / `nvcc --version`)、および推論エンジン (`llama-cpp-python` / `llama.cpp` 等) のバージョン情報**を必ずコンソールへログ出力すること。
- **目的**: プリビルド wheel（CUDA バージョン・Python ABI）の適合性やランタイム不整合をログから即座に特定できるようにするため。

---

## 7. コア設計・実装原則（Colab Studio 標準準拠）

### 原則 1: 単一責務コードブロック (Single-Responsibility Code Cells)
- **1セル＝1処理**: 相互に関係のない処理を同一のコードセルに混在させることを禁止する。
- 設定、ロガー、状態管理、各 API ルーター、メインサーバーはセルを1つずつ完全に分けて記述する。

### 原則 2: `%%writefile` による宣言的ファイル生成（Python 変数代入の禁止）
- ソースコードを Python 文字列変数（`code = """..."""`）に代入し、`open().write()` 等で書き出すことを**厳格に禁止**する。
- モジュールやスクリプトを生成する際は、コードセルの1行目に必ず `%%writefile <出力先パス>` を記述する。

### 原則 3: 環境変数の厳格検証とデフォルト値フォールバック禁止
- コード内で `os.getenv("KEY", "default_value")` のようにデフォルト値をハードコードしてフォールバックすることを**厳格に禁止**する。すべての設定値は `.env` から直接取得する。
- **4大標準環境変数 (`TUNNEL_HOST`, `TUNNEL_PORT`, `TUNNEL_HOSTNAME`, `LLM_API_KEY`) の定義義務**: これらおよび `MODEL_NAME` 等の必須項目が未定義または空文字の場合、不足項目をエラーログに明記して即座に実行を停止する。
- **`LLM_API_KEY` の直接コンソール表示**: マスク表示（`設定済み`）を行わず、設定読み込みセルで `LLM_API_KEY` の値を直接コンソールへ出力する。

### 原則 4: API エンドポイントごとのファイル分離 (`routers/`)
- 全エンドポイントを単一の `server.py` に記述することを禁止する。
- 標準モジュール構成:
  - `routers/health.py`: 死活監視用 (`GET /healthz`)
  - `routers/status.py`: モデル状態・詳細エラー・GPU/VRAM 情報取得用 (`GET /api/v1/status`)
  - `routers/chat.py`: OpenAI 互換チャット補完 (`POST /v1/chat/completions` / ChatML・ストリーミング・`<think>` 長文対応)
  - `routers/models.py`: 利用可能モデル一覧 (`GET /v1/models` / OpenAI 仕様準拠)
  - `routers/<feature>.py`: 各業務・専用推論ロジック
  - `server.py`: 各ルーターの `include_router` のみを行う薄いエントリーポイント

### 原則 5: モデルロード & 実行時エラーの完全ハンドリング
- モデルのロード処理は `try-except` で例外を捕捉し、スタックトレースとエラーメッセージを状態管理オブジェクト（`ServerState`）に保持する。
- ロード失敗時も FastAPI サーバー自体はクラッシュさせず、`GET /api/v1/status` で失敗原因を取得可能にする。
- クライアント/ノートブック側は `/api/v1/status` をポーリングし、`model_status == 'ready'`（または `failed`）になるまで VRAM 消費状況をログ出力しながら待機する。

### 原則 6: サーバー & Cloudflare Tunnel ログの非同期コンソール出力
- `CHECKPOINT`、`API_IO`、`ERROR` を非同期キュー経由でスレッドセーフにコンソールへフラッシュ出力する。
- バックグラウンド実行される `cloudflared` の出力も `logs/tunnel.log` に保存しつつ、非同期でコンソールへ出力可能にする。

### 原則 7: 隔離された仮想環境 (`uv venv`) への依存インストール
- システム Python への `!pip install` やグローバルパッケージ導入を**厳格に禁止**する。
- `current_py = sys.executable` を取得し、`!UV_SYSTEM_PYTHON=0 uv venv --allow-existing --python {current_py} {VENV_DIR}` で独立環境を作成する。
- すべての Python 依存ライブラリは `!uv pip install --python {VENV_DIR}/bin/python ...` で導入し、サーバー起動も `{VENV_DIR}/bin/python` / `{VENV_DIR}/bin/uvicorn` を明示して実行する。

### 原則 8: 既存プロセスの事前強制解放（起動の冪等性保証）
- サーバー起動セル・トンネル起動セルの冒頭で、対象ポート・プロセスを必ず事前解放する（例: `!fuser -k -n tcp {PORT} 2>/dev/null || true`、`!pkill -9 -f uvicorn || true`、`!pkill -9 -f cloudflared || true`）。

### 原則 9: 一時作業領域 & キャッシュの自動クリーンアップ（ディスク枯渇防止）
- 一時ファイルは処理完了時および例外発生時にも確実に `try-finally` 内で削除（`shutil.rmtree` / `os.unlink`）する。
- `!uv cache clean` や古いログファイルの自動ローテーションを組み込む。

### 原則 10: 推論リクエストの JST 日時・実訪問元 IP・入力テキストのコンソール出力規約
- **日本標準時（JST / UTC+9）固定**: `datetime.timezone(datetime.timedelta(hours=9))` で `YYYY-MM-DD HH:MM:SS JST` を出力（UTC 禁止）。
- **実 IP 特定**: `CF-Connecting-IP` → `X-Forwarded-For` → `request.client.host` の優先順位で取得。
- **入力プレビュー**: 最新 `user` メッセージまたは `prompt` を1行（最大 100〜120文字）で表示。
- **標準ログ形式**:
  ```text
  [INFERENCE REQUEST] [2026-11-08 01:10:00 JST] IP: 203.0.113.195 | Input: "プロジェクトの概要を教えて" | msgs: 2, stream: True
  [INFERENCE COMPLETED] [2026-11-08 01:10:02 JST] IP: 203.0.113.195 | Tokens: 128 | Duration: 1.85s
  ```

---

## 8. 実装ベストプラクティス（ストリーミング・警告抑制）

- **`subprocess` 出力のリアルタイムストリーミング**:
  - `subprocess.run(...)` ではなく `subprocess.Popen(..., stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)` で1行ずつ `print(line, end="", flush=True)` へ流すヘルパー（`run_stream` 等）を使用する。
- **警告・冗長出力の抑制規約**:
  - CMake: `-Wno-dev`, `-DCMAKE_C_FLAGS=-w`, `-DCMAKE_CXX_FLAGS=-w`, `-DCMAKE_CUDA_FLAGS=-w`
  - `apt-get`: `DEBIAN_FRONTEND=noninteractive apt-get -qq update && apt-get -qq install -y ...`
  - `uv pip` / `pip`: `-q`
  - `curl` / `wget`: `curl -fsSL` / `wget -q`
  - `git`: `git clone -q` / `git pull -q`
  - Python: `PYTHONWARNINGS="ignore"` または `python -W ignore`

## 8. Private Dataset の優先活用（ディスク・時間節約）
- Kaggle の書き込み可能ディスク容量は限られているため、大容量モデル（20GB+ の GGUF 等）や時間がかかる重いビルド成果物は、毎回ダウンロード／コンパイルするのではなく、可能な限り **Kaggle Private Dataset**（`kernel-metadata.json` の `dataset_sources` に指定し、`/kaggle/input/<dataset-slug>/` から読み取り専用で参照）を利用すること。

## 9. `README.html` および `http.rest` の同時作成要件（厳守）
- ノートブック（`.ipynb`）および `.env` を新規作成する際は、必ず同一ディレクトリ内に以下の2ファイルも同時に作成すること。
  1. **`README.html`**: `readme-html-skill`（Rule.11 / Rule.14 準拠の完全自己完結型 HTML、ハイレベル＆インフラレベルの2種類のインライン SVG 図解を含む）による技術仕様書。
  2. **`http.rest`**: VS Code REST Client 用の疎通・推論テストファイル。以下の要件を厳守すること。
     - **全APIエンドポイントの網羅**: ノートブックで作成・公開する**すべてのAPIエンドポイント**（`/healthz`, `/api/v1/status`, `/v1/models`, `/v1/chat/completions` およびその他固有の生成・管理エンドポイント等）をテストするリクエストケースを、ローカルおよび Tunnel 経由の双方について実装すること。
     - **`.env` 定義値の動的参照（ハードコピー厳禁）**: APIキー、ベースURL、ポート、モデル名等の必要な変数値は、`http.rest` 内に直接ハードコピーせず、同一ディレクトリの `.env` ファイルから **`{{$dotenv <変数名>}}`** 構文を用いて動的に参照すること。
       ```http
       @localUrl = http://127.0.0.1:{{$dotenv PORT}}
       @tunnelUrl = {{$dotenv TUNNEL_URL}}
       @apiKey = {{$dotenv API_KEY}}
       ```
