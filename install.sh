#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="kaggle-notebook"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${HOME}/.gemini/antigravity-cli/skills/${SKILL_NAME}"

mkdir -p "${TARGET_DIR}/scripts"
cp -f "${SRC_DIR}/SKILL.md" "${TARGET_DIR}/SKILL.md"
if [[ -f "${SRC_DIR}/scripts/install_llama_cpp.sh" ]]; then
  cp -f "${SRC_DIR}/scripts/install_llama_cpp.sh" "${TARGET_DIR}/scripts/install_llama_cpp.sh"
  chmod +x "${TARGET_DIR}/scripts/install_llama_cpp.sh"
fi
echo "✅ Installed ${SKILL_NAME} to ${TARGET_DIR}"
