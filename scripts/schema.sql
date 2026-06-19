-- =====================================================
-- ППРГ Database Schema — запусти один раз в SQL Editor
-- https://supabase.com/dashboard/project/dbkevxvpyhprmzrrceic/sql/new
-- =====================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Industries
CREATE TABLE IF NOT EXISTS public.industries (
  id   SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  icon TEXT DEFAULT '📊',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Profiles (auto-created on signup via trigger)
CREATE TABLE IF NOT EXISTS public.profiles (
  id               UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username         TEXT UNIQUE,
  surveys_completed INTEGER DEFAULT 0,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

-- Surveys
CREATE TABLE IF NOT EXISTS public.surveys (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  industry_id   INTEGER REFERENCES public.industries(id),
  title         TEXT NOT NULL,
  is_system     BOOLEAN DEFAULT FALSE,
  is_active     BOOLEAN DEFAULT TRUE,
  response_count INTEGER DEFAULT 0,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Questions (5 per survey)
CREATE TABLE IF NOT EXISTS public.questions (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  survey_id  UUID REFERENCES public.surveys(id) ON DELETE CASCADE,
  order_num  INTEGER NOT NULL CHECK (order_num BETWEEN 1 AND 5),
  text       TEXT NOT NULL,
  UNIQUE(survey_id, order_num)
);

-- Responses (one per user per survey)
CREATE TABLE IF NOT EXISTS public.responses (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  survey_id  UUID REFERENCES public.surveys(id) ON DELETE CASCADE,
  user_id    UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  answers    JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(survey_id, user_id)
);

-- ── Trigger: auto-create profile on signup ──────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, username)
  VALUES (NEW.id, NEW.raw_user_meta_data->>'username')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ── Trigger: update counters on new response ────────────────
CREATE OR REPLACE FUNCTION public.handle_new_response()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.surveys  SET response_count    = response_count    + 1 WHERE id = NEW.survey_id;
  UPDATE public.profiles SET surveys_completed = surveys_completed + 1 WHERE id = NEW.user_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_response_created ON public.responses;
CREATE TRIGGER on_response_created
  AFTER INSERT ON public.responses
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_response();

-- ── Row Level Security ───────────────────────────────────────
ALTER TABLE public.industries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.surveys    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.questions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.responses  ENABLE ROW LEVEL SECURITY;

-- Industries: все читают
CREATE POLICY "industries_read" ON public.industries FOR SELECT USING (true);

-- Profiles: только своё
CREATE POLICY "profiles_own" ON public.profiles USING (auth.uid() = id);

-- Surveys: все читают активные; создаёт/меняет только владелец
CREATE POLICY "surveys_read"       ON public.surveys FOR SELECT USING (is_active = true);
CREATE POLICY "surveys_insert"     ON public.surveys FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "surveys_update_own" ON public.surveys FOR UPDATE USING (auth.uid() = user_id);

-- Questions: все читают
CREATE POLICY "questions_read" ON public.questions FOR SELECT USING (true);

-- Responses: создаёт и читает только свои
CREATE POLICY "responses_insert" ON public.responses FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "responses_own"    ON public.responses FOR SELECT USING (auth.uid() = user_id);

-- ── Service role view: для API подсчёта % ответов ───────────
-- Эта view позволяет API суммировать ответы без раскрытия личных данных
CREATE OR REPLACE VIEW public.survey_results AS
SELECT
  r.survey_id,
  q.order_num,
  q.text AS question_text,
  COUNT(*) AS total,
  SUM(CASE WHEN (r.answers->>(q.order_num::text))::boolean = true THEN 1 ELSE 0 END) AS yes_count,
  SUM(CASE WHEN (r.answers->>(q.order_num::text))::boolean = false THEN 1 ELSE 0 END) AS no_count
FROM public.responses r
JOIN public.questions q ON q.survey_id = r.survey_id
GROUP BY r.survey_id, q.order_num, q.text;

GRANT SELECT ON public.survey_results TO authenticated;
GRANT SELECT ON public.survey_results TO service_role;
