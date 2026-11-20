import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { upstream } from './proxy.ts';
const plan=(path:string,params:Record<string,string>={})=>upstream(new URL('https://local.test/?'+new URLSearchParams({path,...params})));
test('fixed tile host/style/coordinates and no key forwarding',()=>{
  const p=plan('/v1/tile/osm-carto/16/47774/20701.png',{apiKey:'evil'});
  assert.equal(p.url.host,'maps.geoapify.com'); assert.equal(p.url.search,'');
  for(const path of ['https://evil.test','/v1/tile/osm-carto/25/1/1.png','/v1/tile/osm-carto/1/4/4.png']) assert.throws(()=>plan(path));
});
test('local search parameters fixed and bounded',()=>{
  const p=plan('/v1/geocode/autocomplete',{text:'Пушкина 20',filter:'evil',apiKey:'evil'});
  assert.equal(p.url.searchParams.get('filter'),'countrycode:ru');
  assert.equal(p.url.searchParams.get('bias'),'proximity:82.43,55');
  assert.equal(p.url.searchParams.get('apiKey'),null);
  assert.throws(()=>plan('/v1/geocode/autocomplete',{text:'x'}));
});
test('reverse and route coordinates enforce latitude/longitude bounds',()=>{
  const p=plan('/v1/geocode/reverse',{lat:'55',lon:'82.43'});
  assert.equal(p.url.searchParams.get('lat'),'55');
  assert.throws(()=>plan('/v1/geocode/reverse',{lat:'91',lon:'55'}));
  assert.equal(plan('/v1/routing',{waypoints:'55,82.43|55.01,82.44'}).units,10);
  assert.throws(()=>plan('/v1/routing',{waypoints:'55,82|NaN,82'}));
});
