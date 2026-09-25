# Power Monitor MQTT Publisher Makefile

SCRIPT_NAME := power-monitor-mqtt.sh
INSTALL_DIR := $(HOME)/.local/bin
CONFIG_DIR := $(HOME)/.config/power-monitor-mqtt
CONFIG_FILE := $(CONFIG_DIR)/config
# Default LOG_FILE directory in config.example; a custom LOG_FILE is not removed by clean.
LOG_DIR := $(HOME)/Library/Logs/power-monitor-mqtt

.DEFAULT_GOAL := help
.PHONY: clean deps help install setup-config test uninstall

help: ## Show this help message
	@echo "Power Monitor MQTT Publisher"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "} {printf "  %-13s%s\n", $$1, $$2}'

deps: ## Install dependencies via Homebrew
	brew install mosquitto jq

# The config holds the MQTT password, so it is readable only by the owner.
setup-config: ## Create the config file from config.example
	@install -d -m 700 $(CONFIG_DIR)
	@if [ -f $(CONFIG_FILE) ]; then \
		echo "Configuration file already exists at $(CONFIG_FILE)"; \
	else \
		install -m 600 config.example $(CONFIG_FILE); \
		echo "Configuration file created at $(CONFIG_FILE)"; \
		echo "Edit it before running the script."; \
	fi

install: setup-config ## Install the script to ~/.local/bin
	@install -d $(INSTALL_DIR)
	@install -m 755 $(SCRIPT_NAME) $(INSTALL_DIR)/
	@echo "Script installed to $(INSTALL_DIR)/$(SCRIPT_NAME)"

uninstall: ## Remove the installed script
	rm -f $(INSTALL_DIR)/$(SCRIPT_NAME)

test: ## Run the script in test mode
	./$(SCRIPT_NAME) --test

clean: ## Remove the config directory and logs
	rm -rf $(CONFIG_DIR) $(LOG_DIR)
