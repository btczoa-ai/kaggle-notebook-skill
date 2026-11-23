---
name: kaggle-notebook
description: Kaggle GPU (T4 x2 / 32GB VRAM) 環境上で `kaggle` CLI (`kaggle kernels push`) を用いて大規模 GGUF LLM 推論サーバー（FastAPI + llama-cpp-python/llama.cpp + Cloudflare Tunnel）をデプロイ・起動・検証するための専用スキル。
---

# Kaggle LLM Studio Deployment & Operations Standards

Kaggle 環境（`/kaggle/working`）で `kaggle kernels push` により大規模 GGUF LLM 推論サーバーを自動デプロイ・起動・検証する標準規約です。

---

## 1. 環境分離とストレージ規約（厳守）

| 領域 | パス・設定 | 役割・制約 |
| :--- | :--- | :--- |
| **作業ディレクトリ** | `/kaggle/working` | 軽量ソースコード・ログのみ保持（成果物アーカイブ対象）。**.venv や大容量モデルの配置は厳禁**。 |
| **一時ディレクトリ** | `/tmp` | `VENV_DIR=/tmp/.venv`、`MODELS_DIR=/tmp/models` に指定し重量物を退避。 |
| **Private Dataset** | `/kaggle/input/<slug>/` | 20GB+ モデルや大容量成果物は Dataset 経由でマウントしダウンロード・ビルドをスキップ。 |

---

## 2. 推論バックエンド導入規約（ソースビルド絶対禁止）

Kaggle 環境での `llama.cpp` のソースビルド（CMake）は CMake エラーや OOM（Error 137）を招くため**厳格に禁止**。以下のいずれかを採用すること。

1. **プリビルド wheel (`llama-cpp-python[server]`)**:
   - `--extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cu124` で導入。
   - `nvidia-cuda-runtime-cu12`, `nvidia-cublas-cu12` を同時導入し、`LD_LIBRARY_PATH` に nvidia 配下および `/usr/local/cuda/lib64` を通して `libcudart.so.12` 欠落を防止。
2. **公式ネイティブバイナリ (`llama-server`)**:
   - Python 3.13 / CUDA 13 等で適合 wheel が無い場合、`ggml-org/llama.cpp` 公式 GitHub Releases の Ubuntu x64 CUDA 13 プリコンパイル済みバイナリを取得して `/opt/llama.cpp` へ展開（参考: `scripts/install_llama_cpp.sh`）。

---

## 3. ノートブック実装原則

### 3.1. 構造・ライフサイクル設計
- **事前環境ダンプ**: ノートブック開始直後に OS、Python、CUDA/GPU (`nvidia-smi`)、推論エンジンのバージョンを出力。
- **事前ファイル名検証**: Hugging Face API (`https://huggingface.co/api/models/<repo>/tree/main`) で実 GGUF ファイル名を確認（404 防止）。
- **バッチ終了設計**: 先頭セルで `%%writefile .env` を実行。最終セルは無限ループを避け、状態スナップショット出力で正常終了（`KernelWorkerStatus.COMPLETE`）させる。
- **起動の冪等性**: 起動前に `fuser -k -n tcp {PORT}`、`pkill -9 -f uvicorn`、`pkill -9 -f cloudflared` で対象プロセスを解放。

### 3.2. コード設計・分離
- **単一責務**: 1セル＝1処理。設定、ロガー、状態管理、ルーター、メインサーバーを別セルに記述。
- **`%%writefile` 厳守**: Python 文字列変数へのコード代入・ファイル書き込みを禁止し、コードセルの先頭に `%%writefile <path>` を使用。
- **独立仮想環境 (`uv venv`)**: グローバル pip インストールを禁止。`!UV_SYSTEM_PYTHON=0 uv venv --python {sys.executable} {VENV_DIR}` を作成し、明示的パスで実行。
- **API ルーター分離 (`routers/`)**:
  - `routers/health.py`: `GET /healthz`
  - `routers/status.py`: `GET /api/v1/status`（GPU/VRAM情報、例外発生時のスタックトレース取得）
  - `routers/chat.py`: `POST /v1/chat/completions`（OpenAI互換・ストリーミング・`<think>`対応）
  - `routers/models.py`: `GET /v1/models`
  - `server.py`: 各ルーターを `include_router` する薄いエントリーポイント。

### 3.3. 環境変数・ネットワーク
- **厳格検証**: `os.getenv` のデフォルト値フォールバックを禁止。`.env` の必須キー（`TUNNEL_HOST`, `TUNNEL_PORT`, `TUNNEL_HOSTNAME`, `LLM_API_KEY`, `MODEL_NAME`）が未定義の場合は即座に Halt。
- **ポート統合**: `.env` に `TUNNEL_PORT` のみを定義し、推論サーバーポートは `TUNNEL_PORT + 1` を自動割り当て。
- **APIキー出力**: 設定読み込みセルで `LLM_API_KEY` の値を直接コンソールに出力。

---

## 4. ログ出力規約

- **リアルタイムストリーミング**: `subprocess.Popen` を用い、`print(line, end="", flush=True)` でリアルタイムにコンソールへフラッシュ出力。
- **冗長ログ抑制**: `apt-get -qq`、`pip -q`、`curl -fsSL`、`git -q`、`PYTHONWARNINGS="ignore"` を徹底。
- **推論リクエストログ形式**:
  - JST 時刻（`UTC+9` 固定）、実 IP（`CF-Connecting-IP` → `X-Forwarded-For` → `client.host`）、入力プレビュー（最大120文字）を出力。
  ```text
  [INFERENCE REQUEST] [2026-11-20 21:40:00 JST] IP: 203.0.113.195 | Input: "プロジェクトの概要を教えて" | msgs: 2, stream: True
  [INFERENCE COMPLETED] [2026-11-20 21:40:02 JST] IP: 203.0.113.195 | Tokens: 128 | Duration: 1.85s
  ```

---

## 5. 同梱ファイル作成要件（厳守）

ノートブック（`.ipynb`）および `.env` と同一ディレクトリに、以下2ファイルを必ず作成すること。

1. **`README.html`**:
   - `readme-html-skill`（Rule.11 / Rule.14 準拠）による完全自己完結型技術仕様書。
   - ハイレベル（論理機能）＆ インフラレベル（物理・ネットワーク）の2種類のインライン SVG 図解を必須収録。
2. **`http.rest`**:
   - VS Code REST Client 用の疎通・推論テストファイル。
   - 全エンドポイント（`/healthz`, `/api/v1/status`, `/v1/models`, `/v1/chat/completions` 等）の Local / Tunnel 経由テストを網羅。
   - **ハードコード厳禁**: すべての変数（URL、キー、ポート）は同一ディレクトリの `.env` から `{{$dotenv <KEY>}}` で動的参照。
     ```http
     @localUrl = http://127.0.0.1:{{$dotenv PORT}}
     @tunnelUrl = {{$dotenv TUNNEL_URL}}
     @apiKey = {{$dotenv API_KEY}}
     ```
