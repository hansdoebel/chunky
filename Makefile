.DEFAULT_GOAL := build

.PHONY: build run test test-python test-worker build-web test-web test-all clean open-xcode \
       services qdrant ollama \
       setup-venv first-launch doctor test-setup install package-development

doctor:
	python3 tools/macos_preflight.py

test-setup:
	python3 -m unittest discover -s tools -p "test_macos_*.py" -v

build: doctor
	xcodebuild -quiet -project Chunky.xcodeproj -scheme Chunky -configuration Debug -derivedDataPath "$(CURDIR)/build/DerivedData" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

run: build
	open "$(CURDIR)/build/DerivedData/Build/Products/Debug/Chunky.app"

install: build
	python3 tools/macos_distribution.py install --app "$(CURDIR)/build/DerivedData/Build/Products/Debug/Chunky.app"

package-development: build
	python3 tools/macos_distribution.py package --development --app "$(CURDIR)/build/DerivedData/Build/Products/Debug/Chunky.app" --output "$(CURDIR)/dist/development"

test:
	xcodebuild test -scheme Chunky -destination 'platform=macOS' -allowProvisioningUpdates

test-python:
	cd Chunky/Resources/Scripts && python3 -m unittest test_docling_convert test_fastembed_daemon -v

test-integration:
	cd Chunky/Resources/Scripts && ~/.chunky-venv/bin/python3 -m unittest test_docling_integration -v

test-worker:
	cd worker && python3 -m pytest -q

build-web:
	cd worker/web && bun install --frozen-lockfile
	cd worker/web && bun run check
	cd worker/web && bun run build

test-web: build-web
	cd worker/web && bun run test:unit
	cd worker/web && bunx playwright install chromium
	cd worker/web && bun run test:browser

test-all: test test-python test-worker test-integration

clean:
	xcodebuild -project Chunky.xcodeproj -scheme Chunky -derivedDataPath "$(CURDIR)/build/DerivedData" clean

open-xcode:
	open Chunky.xcodeproj

first-launch:
	xcodebuild -runFirstLaunch

qdrant:
	docker run -d --name chunky-qdrant-cli -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 -v chunky-qdrant:/qdrant/storage qdrant/qdrant:v1.20.2

ollama:
	ollama serve

services: qdrant ollama

setup-venv:
	python3.12 tools/setup_macos_venv.py
