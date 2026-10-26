import importlib.util
from pathlib import Path
import sys
import unittest
modpath=Path(__file__).resolve().parents[1]/'monitor.py'
spec=importlib.util.spec_from_file_location('jmonitor',modpath)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
base={
 'temperature':{'celsius':56.2},'memory':{'available':'5.2Gi'},
 'mainStorage':{'usagePercent':'3%','available':'855G'},
 'backupStorage':{'usagePercent':'1%','available':'1.7T'},
 'backup':{'lastCompleted':'2026-10-26_03-00-08','lastResult':'success','timerState':'active','timerEnabled':'enabled','nextBackup':'2026-10-27T03:00:00Z'},
 'containers':[{'name':n,'state':'running','health':'healthy'} for n in m.EXPECTED]}
class Tests(unittest.TestCase):
 def test_healthy_with_daily_backup(self):
  from datetime import datetime,timezone
  arr=m.analyze(base,timestamp=datetime(2026,10,26,14,tzinfo=timezone.utc))
  self.assertTrue(all(x['severity']=='ok' for x in arr))
 def test_docker_health_not_configured_not_failure(self):
  data={**base,'containers':[dict(x) for x in base['containers']]}
  data['containers'][0]['health']='not configured'
  a=m.analyze(data,timestamp=m.now())
  c=next(x for x in a if x['code']=='container-'+m.EXPECTED[0])
  self.assertEqual(c['severity'],'ok')
 def test_high_temperature(self):
  data={**base,'temperature':{'celsius':86}}
  a=m.analyze(data,timestamp=m.now())
  self.assertEqual(next(x for x in a if x['code']=='temperature')['severity'],'critical')
 def test_missing_container(self):
  data={**base,'containers':[]}
  a=m.analyze(data,timestamp=m.now())
  self.assertTrue(any(x['code'].startswith('container-') and x['severity']=='critical' for x in a))
 def test_memory_units(self):
  self.assertAlmostEqual(m.gib('512Mi'),0.5)
  self.assertAlmostEqual(m.gib('5.2Gi'),5.2)
if __name__=='__main__':unittest.main()
