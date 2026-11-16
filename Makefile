.PHONY: build run test test-python test-worker build-web test-web test-all clean open-xcode \
       services qdrant ollama \
       setup-venv first-launch

build:
	xcodebuild -quiet -project Chunky.xcodeproj -scheme Chunky -configuration Debug CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

run: build
	open "$$(find ~/Library/Developer/Xcode/DerivedData -name 'Chunky.app' -path '*/Build/Products/Debug/*' | head -1)"

test:
	xcodebuild test -scheme Chunky -destination 'platform=macOS' -allowProvisioningUpdates

test-python:
	cd Chunky/Resources/Scripts && python3 -m unittest test_docling_convert test_fastembed_daemon -v

test-integration:
	cd Chunky/Resources/Scripts && ~/.chunky-venv/bin/python3 -m unittest test_docling_integration -v

test-worker:
	cd worker && python3 -m pytest -q

build-web:
	npm --prefix worker/web ci
	npm --prefix worker/web run check
	npm --prefix worker/web run build

test-web: build-web
	npm --prefix worker/web run test:unit
	cd worker/web && npx playwright install chromium
	npm --prefix worker/web run test:browser

test-all: test test-python test-worker test-integration

clean:
	xcodebuild -project Chunky.xcodeproj -scheme Chunky clean
	rm -rf ~/Library/Developer/Xcode/DerivedData/Chunky-*

open-xcode:
	open Chunky.xcodeproj

first-launch:
	xcodebuild -runFirstLaunch

qdrant:
	docker run -p 6333:6333 -p 6334:6334 -v chunky-qdrant:/qdrant/storage qdrant/qdrant:v1.20.1

ollama:
	ollama serve

services: qdrant ollama

setup-venv:
	python3 -m venv ~/.chunky-venv
	~/.chunky-venv/bin/pip install -r requirements/macos-scripts.txt
