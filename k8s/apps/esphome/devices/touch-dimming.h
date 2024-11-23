// Touchpad Dimming for ESPHome
// Copyright (C) 2022 dr. Sybren A. Stüvel
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#include "esphome/components/binary_sensor/automation.h"
#include "esphome/components/binary_sensor/binary_sensor.h"
#include "esphome/components/esp32_touch/esp32_touch.h"
#include "esphome/components/light/automation.h"
#include "esphome/components/script/script.h"
#include "esphome/core/application.h"
#include "esphome/core/automation.h"
#include "esphome/core/base_automation.h"
#include "esphome/core/log.h"

#include <string>

using namespace esphome;

using ScriptExecuteAction = script::ScriptExecuteAction<script::Script<>>;
using ScriptStopAction = script::ScriptStopAction<script::SingleScript<>>;

class TouchDimmer {
  static constexpr uint64_t dimStartDelayMs = 350;
  static constexpr uint64_t dimPeriodMs = 10;
  static constexpr auto LOGTAG = "TouchDimming";

  std::string name;
  light::LightState *lightMain;
  binary_sensor::BinarySensor *touchSensor;

  script::SingleScript<> *scriptDimStart;
  script::SingleScript<> *scriptDimStop;

  float dimming_dir = 0;

 public:
  TouchDimmer(const std::string &name,
              light::LightState *lightMain,
              binary_sensor::BinarySensor *touchSensor)
      : name(name), lightMain(lightMain), touchSensor(touchSensor)
  {
    ESP_LOGD(LOGTAG,
             "Creating name=%s, light=%s, touch=%s",
             name.c_str(),
             lightMain->get_name().c_str(),
             touchSensor->get_name().c_str());

    createDimStartScript();
    createDimStopScript();
    setupBinarySensor();
  }

 private:
  // Dimming start script, to be called from the 'on_press' handler of the touch pad:
  void createDimStartScript()
  {
    // Wait to see if the 'touch' lasts for long enough:
    auto *startDelayAction = new DelayAction<>();
    startDelayAction->set_delay(dimStartDelayMs + 50);  // Add a little margin.
    App.register_component(startDelayAction);

    // Toggle the dimming direction:
    LambdaAction<> *toggleDimDirLambda = new LambdaAction<>([&]() -> void {
      const float cur_bright = this->lightMain->current_values.get_brightness();
      const bool is_on = this->lightMain->current_values.is_on();

      if (!is_on || this->dimming_dir == 0 || cur_bright <= 0.0f) {
        this->dimming_dir = 1;
        // Once we start increasing the brightness, it should start at 0%.
        this->lightMain->current_values.set_brightness(0.0f);
      }
      else if (cur_bright >= 1.0f) {
        this->dimming_dir = -1;
      }
      else {
        this->dimming_dir *= -1;
      }
    });

    // Perform a dim step every `dimPeriodMs` milliseconds:
    auto *dimDelayAction = new DelayAction<>();
    dimDelayAction->set_delay(dimPeriodMs);
    App.register_component(dimDelayAction);

    // Do the actual dimming:
    LambdaAction<> *dimStepLambda = new LambdaAction<>([&]() -> void {
      const float step = this->dimming_dir * 0.01f;
      const float cur_bright = this->lightMain->current_values.get_brightness();
      const float new_bright = clamp(cur_bright + step, 0.0f, 1.0f);

      {
        auto call = this->lightMain->make_call();
        call.set_brightness(new_bright);
        call.set_transition_length(dimPeriodMs / 2.0f);
        call.set_state(new_bright > 0);
        call.perform();
      }

      if (new_bright <= 0.0f || new_bright >= 0.999f) {
        this->scriptDimStop->execute();
      }
    });

    // Construct the while-loop:
    auto *whileCondition = new binary_sensor::BinarySensorCondition<>(touchSensor, true);
    auto *whileAction = new WhileAction<>(whileCondition);
    whileAction->add_then({dimDelayAction, dimStepLambda});

    // Construct the script:
    scriptDimStart = new script::SingleScript<>();
    scriptDimStart->set_name(name + "__script_dimming_start");

    auto *dimStartAutom = new Automation<>(scriptDimStart);
    dimStartAutom->add_actions({startDelayAction, toggleDimDirLambda, whileAction});
  }

  void createDimStopScript()
  {
    // Stop the dimming script:
    auto *scriptStopAction = new ScriptStopAction(scriptDimStart);

    // Construct the script:
    scriptDimStop = new script::SingleScript<>();
    scriptDimStop->set_name(name + "__script_dimming_stop");

    auto *dimStopAutom = new Automation<>(scriptDimStop);
    dimStopAutom->add_actions({scriptStopAction});
  }

  void setupBinarySensor()
  {
    auto *pressTrigger = new binary_sensor::PressTrigger(touchSensor);
    auto *pressScriptAction = new ScriptExecuteAction(scriptDimStart);
    auto *pressAutomation = new Automation<>(pressTrigger);
    pressAutomation->add_actions({pressScriptAction});

    auto *releaseTrigger = new binary_sensor::ReleaseTrigger(touchSensor);
    auto *releaseScriptAction = new ScriptExecuteAction(scriptDimStop);
    auto *releaseAutomation = new Automation<>(releaseTrigger);
    releaseAutomation->add_actions({releaseScriptAction});

    auto *clickTrigger = new binary_sensor::ClickTrigger(touchSensor, 50, dimStartDelayMs);
    auto *lightToggleAction = new light::ToggleAction<>(lightMain);
    LambdaAction<> *setDimDirectionLambda = new LambdaAction<>([&]() -> void {
      this->dimming_dir = lightMain->current_values.get_brightness() > 0.5f ? 1 : -1;
    });

    auto *clickAutomation = new Automation<>(clickTrigger);
    clickAutomation->add_actions({lightToggleAction, setDimDirectionLambda});
  }
};
