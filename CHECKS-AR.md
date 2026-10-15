# تقرير الفحوص المحلية — هوبا بيتزا

تاريخ تجهيز الحزمة: 15 أكتوبر 2026.

## فحوص نجحت

- `node scripts/check-syntax.mjs`: نجح فحص صياغة JavaScript داخل `index.html` و`admin.html`.
- تحويل صياغي TypeScript لملف Edge Function باستخدام مترجم TypeScript المتاح محليًا: نجح. هذا فحص صياغي فقط، وليس اختبار تشغيل على Deno أو Supabase.
- لا توجد معرفات HTML ثابتة مكررة في `index.html` أو `admin.html`.
- لم تظهر مفاتيح `service_role` أو `sb_secret` في ملفات HTML.
- جرى التحقق أن الترحيل المضمّن في `schema.sql` مطابق للملف `supabase/migrations/202610150001_production_hardening.sql`.
- جرى توحيد مسارات صور المنتجات الـ14 في `seed.sql` على `./assets/hopa-logo.svg`، وهو أصل موجود في الحزمة.
- لا تستخدم ملفات HTML رابط Tailwind Play CDN؛ ملفات CSS تُبنى عبر Vite/Tailwind.

## فحوص لم تُنفّذ

- لم يكتمل تنزيل حزم npm في بيئة التجهيز؛ لذلك لم يتم اعتماد نجاح `npm run build` أو اختبار معاينة `dist/` هنا.
- لم تتوفر قاعدة PostgreSQL/Supabase حية لتشغيل SQL أو اختبار RLS والدوال والأذونات.
- لم تُنشر Edge Function ولم تُضبط أسرارها في مشروع Supabase.
- لم تُرسل طلبات حقيقية أو تُنفّذ اختبارات الشبكة/التكرار/Realtime/البريد الحية.

## بوابة الإطلاق

لا تفتح استقبال طلبات حقيقية قبل أخذ نسخة احتياطية، ومراجعة توافق المخطط، وتطبيق الترحيل على بيئة اختبار، وضبط `HOPA_RATE_LIMIT_SALT` و`HOPA_ALLOWED_ORIGINS`، ونشر `hopa-public-api`، وبناء الموقع، ثم تنفيذ قائمة الاختبارات في `README-AR.md`.
