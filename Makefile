APP_DIR ?= $(HOME)/Applications
BIN_DIR ?= $(HOME)/.local/bin

.PHONY: app install reset-permissions clean

app:
	scripts/build-app.sh

# Installs to a stable path so macOS privacy grants stick to one location.
install: app
	mkdir -p "$(APP_DIR)" "$(BIN_DIR)"
	rm -rf "$(APP_DIR)/Rec.app"
	cp -R build/Rec.app "$(APP_DIR)/Rec.app"
	ln -sf "$(APP_DIR)/Rec.app/Contents/MacOS/rec" "$(BIN_DIR)/rec"
	@echo "installed $(APP_DIR)/Rec.app, linked $(BIN_DIR)/rec"

# Ad-hoc signatures change on every build; if a rebuilt Rec records silence,
# clear its old grants and let macOS prompt again.
reset-permissions:
	tccutil reset Microphone com.callumrowe.rec
	tccutil reset AudioCapture com.callumrowe.rec

clean:
	rm -rf .build build
