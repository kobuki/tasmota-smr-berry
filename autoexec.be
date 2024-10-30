import string
import re
import mqtt

var config = {
    'rulesConf': 'rules.conf',
    'serialRx': 3,
    'serialTx': 1,
    'serialBaud': 115200,
    'simpleTopic': 'smr',
    'baseTopic': string.replace(string.replace(
        tasmota.cmd('FullTopic', true)['FullTopic'],
        '%topic%', tasmota.cmd('Topic', true)['Topic']),
        '%prefix%', tasmota.cmd('Prefix', true)['Prefix3']),
    'useJson': false,
    'meterName': 'ma105',
    'statDepth': 90,
    'debugTelegram': false
}

def log(msg)
    tasmota.log('SMR: ' + msg)
end

def bufFind(buf, needle)
    for i: 0 .. buf.size() - 1
        if buf[i] == needle
            return i
        end
    end
    return -1
end

def readTextFile(file)
    var f = open(file, "r")
    var data = f.read()
    f.close()
    return data
end

var lastHappy = 0
def happyTasmota()
    if tasmota.millis() - lastHappy > 50
        tasmota.yield()
        lastHappy = tasmota.millis()
    end
end

def crc16(data, crc, len)
    for di: 0 .. len - 1
        crc ^= data[di]
        for i: 0 .. 7
            if crc & 0x0001
                crc = (crc >> 1) ^ 0xa001
            else
                crc >>= 1
            end
        end
        happyTasmota()
    end
    return crc
end

class stats
    var depth, stack, pos, cnt

    def init(depth)
        self.depth = depth
        self.stack = bytes()
        self.stack.resize(depth)
        self.pos = 0
        self.cnt = 0
    end

    def push(val)
        self.stack[self.pos] = val ? 1 : 0
        self.pos = (self.pos + 1) % self.depth
        self.cnt += 1
    end

    def getQuality()
        if self.cnt < self.depth return -1 end
        var sum = 0
        for i: 0 .. self.depth - 1
            sum += self.stack[i]
        end
        return sum * 100 / self.depth
    end

end

class smr
    var telegram, rules, ser, crc, wireCrc, eotpos, payloadAvailable, wireStats

    # 1,1-0:32.7.0(@1,Voltage,V,voltage_l1,17
    # 1,0-0:1.0.0(@#),Time,time,time,0

    def init()
        self.telegram = bytes()
        self.rules = {}
        self.crc = nil
        self.eotpos = -1
        self.payloadAvailable = false
        self.wireStats = stats(config['statDepth'])
    
        var cf = readTextFile(config['rulesConf'])
        var cfRules = string.split(cf, "\n")
        for rule: cfRules
            if size(rule) == 0 continue end
            var parts = string.split(rule, ',')
            if parts.size() < 6 || parts[0] < '1' || parts[0] > '9' continue end
            var codeDesc = string.split(parts[1], '(')
            var code = codeDesc[0]
            var vType = 0  # number
            if size(codeDesc[1]) > 1 && codeDesc[1][1] == '#'
                vType = 1  # string
            end
            # obis_code, metric_description, unit, metric_name, vType
            self.rules[code] = [parts[2], parts[3], parts[4], vType]
            happyTasmota()
        end

        self.ser = serial(config['serialRx'], config['serialTx'], config['serialBaud'], serial.SERIAL_8N1, true)
        tasmota.add_fast_loop(/-> self.readTelegram())
    end

    def deinit()
        self.ser.close()
    end

    # 1-0:8.8.0(000023.622*kvarh)
    # 1-0:15.8.0(000223.000*kWh)
    # 1-0:32.7.0(237.2*V)
    # 1-0:31.7.0(002*A)
    # 0-0:96.13.0()
    # !AB12

    def processPayload()
        var obis = string.split(self.telegram.asstring(), '\r\n')
        var rr = re.compile('^([0-9]-[0-9]:[0-9]+\\.[0-9]+\\.[0-9]+)\\(([^*)]*)?[*)]([^()]+)?\\)?')
        var timeStr = tasmota.time_str(tasmota.rtc()['local'])

        for line: obis
            var m = rr.match(line)
            if m == nil || m.size() < 4 continue end
            var code = m[1]
            var rule = self.rules.find(code)
            if rule == nil continue end
            var name = rule[2]
            var value = rule[3] == 1 ? m[2] : real(m[2])
            # log(format('code: %s, desc: %s, unit: %s, name: %s, value: %s', code, rule[0], rule[1], name, value))
            if config['useJson']
                # tele/ma105-meter/SENSOR = {"Time":"2024-10-25T19:06:56","ma105":{"energy_export":102.791}}
                var topic = config['baseTopic'] + 'SENSOR'
                var q = rule[3] == 1 ? '"' : ''
                var payload = format('{"Time":"%s","%s":{"%s":%s}}', timeStr, config['meterName'], name, q + value + q)
                mqtt.publish(topic, payload)
            else
                # tele/ma105-meter/smr/energy_export = 102.791
                var topic = config['baseTopic'] + config['simpleTopic'] + '/' + name
                mqtt.publish(topic, format('%s', value))
            end
            happyTasmota()
        end
    end
    
    def readTelegram()
        if !self.ser.available() return end
        self.payloadAvailable = false
        var buf = self.ser.read()
        self.telegram = buf
        var tries = 500
        self.eotpos = -1
        while tries > 0 && self.eotpos == -1
            tries -= 1
            while self.ser.available()
                buf = self.ser.read()
                self.telegram .. buf
                var eotpos = bufFind(self.telegram, 0x21)
                if eotpos > -1
                    self.eotpos = eotpos
                    self.payloadAvailable = true
                    self.ser.flush()
                    return
                end
            end
        end
    end

    def every_250ms()
        if !self.payloadAvailable return end
        self.wireCrc = string.toupper(self.telegram[self.eotpos + 1 .. self.eotpos + 4].asstring())
        self.crc = crc16(self.telegram, 0, self.eotpos + 1)
        self.crc = format('%04X', self.crc)
        if self.crc == self.wireCrc
            self.wireStats.push(true)
            self.processPayload()
            log('processed payload, CRC OK')
        else
            self.wireStats.push(false)
            log(format('payload CRC error, calculated CRC: %s, CRC on wire: %s', self.crc, self.wireCrc))
        end
        self.payloadAvailable = false

        if self.config['debugTelegram']
            var dtopic = config['baseTopic'] + config['simpleTopic'] + '/telegram'
            var half = self.telegram.size() / 2
            mqtt.publish(dtopic + '1', self.telegram[0 .. half - 1].tohex())
            mqtt.publish(dtopic + '2', self.telegram[half ..].tohex())
            mqtt.publish(dtopic + '_crc', self.crc)
        end

        self.crc = nil
        self.eotpos = -1
        self.telegram = bytes()

        var wq = self.wireStats.getQuality()
        if wq == -1 return end
        if config['useJson']
            var topic = config['baseTopic'] + 'SENSOR'
            var payload = format(
                '{"Time":"%s","%s":{"%s":%d}}', tasmota.time_str(tasmota.rtc()['local']),
                config['meterName'], 'wire_quality', wq)
            mqtt.publish(topic, payload)
        else
            var topic = config['baseTopic'] + config['simpleTopic'] + '/wire_quality'
            mqtt.publish(topic, format('%d', wq))
        end
    end

end

smrDriver = smr()
tasmota.add_driver(smrDriver)
