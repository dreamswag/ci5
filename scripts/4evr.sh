#!/bin/sh
INSTALL_MODE="minimal"
export INSTALL_MODE
curl -sL https://raw.githubusercontent.com/dreamswag/ci5/main/scripts/bootstrap.sh | sh