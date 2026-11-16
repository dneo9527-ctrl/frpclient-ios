#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p verification
swiftc -swift-version 5 -D FRPCLIENT_TESTS \
  ios/FrpClient/FrpcController.swift tests/ControllerSupport.swift tests/ControllerTests.swift \
  -o verification/controller-tests
verification/controller-tests
