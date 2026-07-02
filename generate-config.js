const fs = require('fs');
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('ERROR: SUPABASE_URL and SUPABASE_ANON_KEY env vars must be set');
  process.exit(1);
}
fs.writeFileSync(
  'config.js',
  `const SUPABASE_URL = '${url}';\nconst SUPABASE_ANON_KEY = '${key}';\n`
);
console.log('config.js generated successfully');
