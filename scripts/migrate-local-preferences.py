#!/usr/bin/env python3
"""Personal-machine migration. Never reads Keychain credentials."""
import datetime, os, pathlib, plistlib, shutil
base = pathlib.Path.home() / 'Library/Containers'
old = base/'org.somnoire.Somnoire/Data/Library/Preferences/org.somnoire.Somnoire.plist'
new = base/'io.github.kusanalee.Somnoire/Data/Library/Preferences/io.github.kusanalee.Somnoire.plist'
backup = pathlib.Path.home()/'Library/Application Support/Somnoire Migration'
backup.mkdir(parents=True, exist_ok=True, mode=0o700)
if not old.exists(): raise SystemExit('No old preferences found; use guided setup.')
shutil.copy2(old, backup/('old-preferences-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'.plist'))
if not new.parent.exists(): raise SystemExit('Backup saved. Launch and quit the new app once, then rerun.')
source = plistlib.loads(old.read_bytes())
try:
 current = plistlib.loads(new.read_bytes()) if new.exists() else {}
except PermissionError:
 raise SystemExit('macOS protected the new container. Legacy backup retained; use guided setup. No permissions were bypassed.')
allowed = {'selectedPeripheral':str,'appMode':str,'monitoringEnabled':bool,'appearance':str,'menuBarStyle':str,'energyDisplayUnit':str,'temperatureDisplayUnit':str,'percentagePrecision':int,'onboardingComplete':bool,'onboardingStep':int,'lowBatteryThreshold':int}
import uuid
for key, kind in allowed.items():
 value = source.get(key)
 if type(value) is not kind: continue
 if key == 'selectedPeripheral':
  try: uuid.UUID(value)
  except ValueError: continue
 if key == 'appMode' and value not in ('percentageOnly','fullReadings'): continue
 if key == 'appearance' and value not in ('System','Light','Dark'): continue
 if key == 'menuBarStyle' and value not in ('Default','NouNou'): continue
 if key == 'percentagePrecision' and value not in range(4): continue
 if key == 'onboardingStep' and value not in range(5): continue
 if key == 'lowBatteryThreshold' and value not in (10,15,20,25,30): continue
 if key == 'energyDisplayUnit' and value not in ('Auto','Wh','kWh'): continue
 if key == 'temperatureDisplayUnit' and value not in ('°C','°F'): continue
 current.setdefault(key,value)
for key,value in source.items():
 if key.startswith('lowBatteryLatch.') and type(value) is bool:
  parts=key.split('.')
  try: valid=len(parts)==3 and uuid.UUID(parts[1]) and int(parts[2]) in (10,15,20,25,30)
  except ValueError: valid=False
  if valid: current.setdefault(key,value)
current['lowBatteryAlerts']=False
with new.open('wb') as f: plistlib.dump(current,f)
os.chmod(new,0o600)
print('Validated preferences migrated; alerts disabled. Original data and private backup retained.')
