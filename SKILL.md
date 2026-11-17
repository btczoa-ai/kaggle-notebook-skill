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

## 2. CUDA プリビルド wheel (`llama-cpp-python[server]`) の採用
- Kaggle コンテナでは CMake が `CUDA::cuda_driver` を見つけられず `llama.cpp` ソースビルドが失敗しやすい（また `-j` 無制限は RAM 不足で `Error 137` を起こす）。
- `--extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cu124` でプリビルド wheel を導入し、`nvidia-cuda-runtime-cu12` と `nvidia-cublas-cu12` を同時インストールする。
- サブプロセス起動時に `LD_LIBRARY_PATH` へ `/tmp/.venv/lib/python*/site-packages/nvidia/*/lib` および `/usr/local/cuda/lib64` を追加し、`libcudart.so.12` 欠落エラーを防止する。

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

## 7. `llama.cpp` バックエンド利用時のプリビルド wheel 使用要件（厳守）
- 推論バックエンドとして `llama.cpp` を利用する場合、`llama-cpp-python[server]` は**ソースコンパイルを行わず、必ず公式の CUDA 対応プリビルドバイナリ（wheel）**（例: `--extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cu124`）を使用してインストールすること。
