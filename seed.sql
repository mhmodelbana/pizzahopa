-- Initial Hopa Pizza catalog. These are the menu values from the supplied HTML.
-- Confirm all prices and estimated add-on prices with the restaurant before going live.

insert into public.categories (id, name, icon, is_active, sort_order) values
  ('cat_pizza', 'البيتزا', 'pizza', true, 1),
  ('cat_crepe', 'الكريب', 'chef-hat', true, 2),
  ('cat_sandwich', 'الساندوتشات', 'sandwich', true, 3),
  ('cat_pasta', 'المكرونات', 'utensils', true, 4),
  ('cat_grill', 'المشويات', 'flame', true, 5),
  ('cat_seafood', 'سي فود', 'fish', true, 6)
on conflict (id) do update set name = excluded.name, icon = excluded.icon,
  is_active = excluded.is_active, sort_order = excluded.sort_order;

insert into public.addons (id, group_key, name, price_type, fixed_price, size_prices, is_active, sort_order) values
  ('ad_p1', 'pizza', 'حشو أطراف', 'size_based', null, '{"وسط":50,"كبير":60}'::jsonb, true, 1),
  ('ad_p2', 'pizza', 'إكسترا لحوم', 'size_based', null, '{"وسط":50,"كبير":60}'::jsonb, true, 2),
  ('ad_p3', 'pizza', 'إكسترا جبنة', 'size_based', null, '{"وسط":50,"كبير":60}'::jsonb, true, 3),
  ('ad_p4', 'pizza', 'إكسترا مشروم', 'size_based', null, '{"وسط":50,"كبير":60}'::jsonb, true, 4),
  ('ad_c1', 'crepe', 'بطاطس', 'fixed', 15, '{}'::jsonb, true, 1),
  ('ad_c2', 'crepe', 'موتزاريلا زيادة', 'fixed', 20, '{}'::jsonb, true, 2)
on conflict (id) do update set group_key = excluded.group_key, name = excluded.name,
  price_type = excluded.price_type, fixed_price = excluded.fixed_price,
  size_prices = excluded.size_prices, is_active = excluded.is_active, sort_order = excluded.sort_order;

insert into public.products (id, category_id, name, description, sizes, addon_group, image_url, is_active, sort_order) values
  ('p_m1', 'cat_pizza', 'مكس هوبا', 'مكس هوبا السري باللحوم والجبن', '[{"name":"وسط","price":155},{"name":"كبير","price":170}]'::jsonb, 'pizza', './assets/hopa-logo.svg', true, 1),
  ('p_m2', 'cat_pizza', 'مكس بانية', 'قطع بانية مقرمشة مع الخلطة', '[{"name":"وسط","price":155},{"name":"كبير","price":170}]'::jsonb, 'pizza', './assets/hopa-logo.svg', true, 2),
  ('p_c1', 'cat_pizza', 'شاورما فراخ', 'شاورما دجاج متبلة مع الجبن', '[{"name":"وسط","price":145},{"name":"كبير","price":160}]'::jsonb, 'pizza', './assets/hopa-logo.svg', true, 3),
  ('p_m3', 'cat_pizza', 'شاورما لحمة', 'شاورما لحم بلدي', '[{"name":"وسط","price":150},{"name":"كبير","price":170}]'::jsonb, 'pizza', './assets/hopa-logo.svg', true, 4),
  ('p_ch1', 'cat_pizza', 'عشاق الجبنة', 'مزيج من أشهى أنواع الجبن', '[{"name":"وسط","price":140},{"name":"كبير","price":160}]'::jsonb, 'pizza', './assets/hopa-logo.svg', true, 5),
  ('p_ch2', 'cat_pizza', 'مرجريتا', 'بيتزا الجبنة الكلاسيكية', '[{"name":"وسط","price":125},{"name":"كبير","price":140}]'::jsonb, 'pizza', './assets/hopa-logo.svg', true, 6),
  ('c_1', 'cat_crepe', 'كريب مكس هوبا', 'أفضل كريب بمكس اللحوم والفراخ', '[{"name":"عادي","price":120},{"name":"كونو","price":135}]'::jsonb, 'crepe', './assets/hopa-logo.svg', true, 1),
  ('c_2', 'cat_crepe', 'شيش طاووق', 'شيش طاووق مشوي بصوص الكريب', '[{"name":"عادي","price":115},{"name":"كونو","price":130}]'::jsonb, 'crepe', './assets/hopa-logo.svg', true, 2),
  ('c_3', 'cat_crepe', 'زنجر سوبريم', 'زنجر دجاج حار مقرمش', '[{"name":"عادي","price":110},{"name":"كونو","price":125}]'::jsonb, 'crepe', './assets/hopa-logo.svg', true, 3),
  ('s_1', 'cat_sandwich', 'شاورما لحمة', 'ساندوتش شاورما لحم بلدي', '[{"name":"سوري","price":100},{"name":"M","price":80},{"name":"L","price":95}]'::jsonb, null, './assets/hopa-logo.svg', true, 1),
  ('s_2', 'cat_sandwich', 'زنجر سوبريم', 'صدور دجاج كرسبي مع الخس', '[{"name":"سوري","price":100},{"name":"M","price":80},{"name":"L","price":95}]'::jsonb, null, './assets/hopa-logo.svg', true, 2),
  ('g_1', 'cat_grill', 'فرخة مشوية', 'دجاجة كاملة مشوية على الفحم', '[{"name":"عادي","price":250}]'::jsonb, null, './assets/hopa-logo.svg', true, 1),
  ('g_2', 'cat_grill', 'حواوشي', 'رغيف حواوشي بلدي', '[{"name":"عادي","price":50}]'::jsonb, null, './assets/hopa-logo.svg', true, 2),
  ('ps_1', 'cat_pasta', 'مكرونة شاورما فراخ', 'مكرونة غنية بالصوص وشاورما الدجاج', '[{"name":"عادي","price":115}]'::jsonb, null, './assets/hopa-logo.svg', true, 1)
on conflict (id) do update set category_id = excluded.category_id, name = excluded.name,
  description = excluded.description, sizes = excluded.sizes, addon_group = excluded.addon_group,
  image_url = excluded.image_url, is_active = excluded.is_active, sort_order = excluded.sort_order;

insert into public.store_settings (id, delivery_fee, is_open)
values (1, 15, true)
on conflict (id) do nothing;
