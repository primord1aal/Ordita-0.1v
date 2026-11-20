/** Fixed upstreams and parameters. Never accepts a URL, API key, or redirect. */
export function upstream(input: URL): { url: URL; units: number; bytes: number; type: string } {
  const path = input.searchParams.get('path') ?? '';
  const p = input.searchParams;
  let host = 'api.geoapify.com';
  const out = new URLSearchParams();
  let units = 1, bytes = 256 * 1024, type = 'application/json';
  const coordinate = (key: string, limit: number) => {
    const raw = p.get(key); const value = Number(raw);
    if (!raw || !Number.isFinite(value) || Math.abs(value) > limit) throw Error('invalid');
    return String(value);
  };
  if (/^\/v1\/tile\/(osm-carto|positron|dark-matter)\/\d{1,2}\/\d+\/\d+\.png$/.test(path)) {
    const parts = path.split('/');
    const z = Number(parts[4]), x = Number(parts[5]), y = Number(parts[6].slice(0,-4));
    if (z > 20 || x >= 2 ** z || y >= 2 ** z) throw Error('invalid');
    host = 'maps.geoapify.com'; bytes = 512 * 1024; type = 'image/png';
  } else if (path === '/v1/geocode/autocomplete') {
    const text = (p.get('text') ?? '').trim();
    if (text.length < 3 || text.length > 250) throw Error('invalid');
    out.set('text', text); out.set('filter','countrycode:ru'); out.set('bias','proximity:82.43,55');
    out.set('lang','ru'); out.set('limit','5'); out.set('format','json');
  } else if (path === '/v1/geocode/reverse') {
    out.set('lat',coordinate('lat',90)); out.set('lon',coordinate('lon',180));
    out.set('lang','ru'); out.set('limit','1'); out.set('format','json');
  } else if (path === '/v1/routing') {
    const waypoints = p.get('waypoints') ?? '';
    const pairs = waypoints.split('|');
    if (pairs.length !== 2) throw Error('invalid');
    for (const pair of pairs) {
      const v = pair.split(',').map(Number);
      if (v.length !== 2 || !v.every(Number.isFinite) || Math.abs(v[0]) > 90 || Math.abs(v[1]) > 180) throw Error('invalid');
    }
    out.set('waypoints',waypoints); out.set('mode','drive'); out.set('format','geojson');
    out.set('units','metric'); out.set('lang','ru'); units = 10; bytes = 1024 * 1024;
  } else throw Error('invalid');
  const url = new URL(`https://${host}${path}`); url.search = out.toString();
  return {url,units,bytes,type};
}
