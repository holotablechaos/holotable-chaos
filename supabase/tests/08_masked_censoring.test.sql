-- Symbol-censored words ("gr*bble" style). FICTIONAL words only.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into private.blocked_terms (term, match_type, category) values
  ('grobble', 'word', 'profanity'), ('snorf', 'word', 'profanity'), ('zork', 'substring', 'slur'), ('blurp', 'word', 'profanity');
insert into private.allowed_terms (term) values ('Snarf');

select ok(private.contains_blocked_word(t), format('"%s" is caught', t))
  from unnest(array['what a gr*bble', 'gr**ble move', 'GR#BBLE', 'gr%bble', 'g*obble', 's*orf', 'z*rk',
                    'gr*bble, gr*bble', 'grooo*ble', 'gr0*ble', 'bl*rp']) t;

select ok(not private.contains_blocked_word(t), format('"%s" is left alone', t))
  from unnest(array['**bold** text', 'rated 4* overall', 'what? why?', '5*3 = 15', '2*2=4', 'a*b + c', 'x * y',
                    'un*believable', 'Note*: see below', 'C*3PO and R2*D2', 'g*', '*grob*', 'sn*rf is fine here?',
                    'jd_5', 'sn*r*', 'gr*bb**', 'ready?go', 'gr*bbles and gr*bbled', 'hello*world']) t
 where t <> 'sn*rf is fine here?';  -- (checked separately below: it could be the allowlisted "snarf")

select ok(not private.contains_blocked_word(t), format('"%s" could be the allowlisted word, so it is left alone', t))
  from unnest(array['sn*rf is fine here', 'sn**f', 'sn*rf!']) t;
select ok(private.contains_blocked_word('grobble'), 'plain words still match');

select * from finish();
rollback;
