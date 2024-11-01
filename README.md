### Summary

This project is an attempt to create a Tasmota Berry driver for OBIS ASCII format (DSMR) telegrams for smart utility meters equipped with a P1 data port. Tasmota already has a great [native driver](https://tasmota.github.io/docs/Smart-Meter-Interface/) for the same task, but it unfortunately doesn't feature CRC checksum verification. It's a necessity for meters where serial data transfer is not 100% reliable (such as that of the author's). It was also a good hobby project to learn the Berry embedded script language.

### Goals

 * simple installation and setup
 * meter descriptor format should be (mostly) compatible with the [Tasmota Smart Meter interface](https://tasmota.github.io/docs/Smart-Meter-Interface/)
 * support CRC checksumming
 * support basic configuration via plaintext file (formatted as JSON)
 * using extra hardware besides a Tasmota-supported ESP32, like a serial data signal inverter, should nod be required

### Requirements and basic setup

#### Hardware

 * any ESP32 device supported by Tasmota with available pins for serial RX/TX pins (configurable) available
 * some wiring
   * for basic connection setup, please refer to [this page](https://github.com/bobsiboo/esp8266_p1meter-Belgium?tab=readme-ov-file#connecting-to-the-p1-meter), for example
   * note that it's not necessary to use the inverter circuit per [Tasmota instructions](https://tasmota.github.io/docs/P1-Smart-Meter/)
   * an option to use with the inverter circuit might be added later

#### Software
 * Tasmota 14+ ESP32 (should run on older versions - untested)
 * any Tasmota32 firmware with Berry support (standard ones should do)

### Installation

#### Required files

Clone/download this repository locally. Make a copy of `smr-config.sample.json` as `smr-config.json`, `smr-rules.sample.conf` as `smr-rules.conf`. A few settings and probably the whole rules file will need to be updated.

#### The rules configuration file

The sample rules file contains a definition for the author's meter, but any OBIS ASCII meter definition from [the available ones](https://tasmota.github.io/docs/Smart-Meter-Interface/#smart-meter-descriptors) can be used. Just copy the part after `>M 1`, up to the `#`. Only the lines for the individual metrics are interpreted. They can be customized per the description on the same page. Note that the author, so far, was only able to test with their own device.

From the descriptor lines, only the following fields are used: OBIS code, description, unit, name. In the decoder part of the 2nd field, only the `(@` and `(#` semantics are interpreted (numeric vs. string).

#### The driver configuration file

Setting name       | Required | Description
------------------ | -------- | -----------
rulesConf          | Yes      | Path to the metric rules configuration file.
serialRx           | Yes      | UART RX pin number.
serialTx           | Yes      | UART TX pin number (not used but required).
serialBaud         | Yes      | Baud rate for serial communication.
topic              | Yes      | MQTT base topic for publishing telemetry data, if not using `tasmotaTele`.
meterName          | Yes      | Name of the meter, used in various places for messages and logging.
tasmotaTele        | Yes      | Use JSON-formatted Tasmota teleperiod sensor messages under `tele/<tasmota name>/SENSOR`.
statDepth          | Yes      | Number of latest telegrams to keep validity stats for, requires `"ignoreCrc": false`. The `wire_quality` topic shows the percentage of the telegrams validated by CRC.
debugTelegram      | Yes      | Enable raw (hex encoded) telegram MQTT messages and some metadata to aid in debugging telegrams.
ignoreCrc          | Yes      | Ignore CRC checks (true/false). `false` also disables stats.
webSensors         | No       | JSON array with names for sensors to display on Tasmota web UI main page.
teleperiodSensors  | No       | JSON array with names for sensors to add to standard Tasmota teleperiod messages. Requires `"tasmotaTele": true`.

#### Final steps

Copy the 3 files: `autoexec.be`, `smr-config.json` and `smr-rules.conf` to the root of the Tasmota file system using the `Manage File system` web UI or other means. Then restart Tasmota and enjoy.
