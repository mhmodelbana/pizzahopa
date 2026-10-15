-- Use the packaged logo for all catalog products (the storefront reads this asset directly too).
-- Run only after confirming this relative URL is deployed beside index.html.
update public.products
set image_url = './assets/hopa-logo.svg', updated_at = now()
where image_url is distinct from './assets/hopa-logo.svg';
