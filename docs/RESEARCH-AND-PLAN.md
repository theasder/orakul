# orakul.ai — research and plan (v1)

A Cruxwing branch for the Russian-speaking developer community. This file is the
working document: research first, then the decisions the research supports, then
what is still assumption. Every claim that came from a source is cited; every
claim that did not is marked **ASSUMPTION** so it cannot quietly become fact.

Status: v1, 2026-08-11. Research covers the Q&A gap, in-call pain, the tool
landscape and the model choice. Not yet researched: Telegram chat structure at
first hand, willingness to pay, GitHub-stars mechanics.

---

## 1. The gap this product enters

### 1.1 The Q&A layer collapsed, and nothing replaced it

Stack Overflow's decline is measured, not vibes: April 2025 publications fell
**64% year-on-year and 90% from the April 2020 peak**, with the slide starting
June 2020 and LLMs accelerating rather than starting it.[^so-decline] The
cultural cause is older than the traffic loss — moderation that reads as hostile
to newcomers, questions closed as "duplicate" or "too simple", and a bar for an
acceptable question so high that new participants stopped trying, which starves
the veterans of interesting questions in turn.[^so-mod]

That is the global story. The Russian-language layer inherits it **and** is
thinner to begin with. On Хабр Q&A the recurring complaints are structural, not
incidental: questions arrive with too little information to answer, threads die
almost immediately once they are no longer new, and the tag system duplicates and
overlaps itself.[^qna] A question that goes stale in a day is a question whose
answer is never found again by the next person with the same problem — the
searchability failure and the response-time failure are one failure.

**What this means for orakul:** the opportunity is not "build a better forum".
The forum model is what died. The opportunity is answering from the material a
team already produces — its calls, its repos, its trackers — where the answer is
specific to *this* codebase and *this* team's decisions, and cannot be closed as
a duplicate.

### 1.2 For a developer, the call itself IS the pain

Corrected after a founder note, and it changes the pitch more than it changes
the code. The framing above — decisions get lost, so make meetings searchable —
is a **manager's** pain. A developer's pain is one level earlier: the meeting
exists at all. Russian practitioner writing states it outright, up to
"Продуктивность в тишине: отказ от совещаний как идеал", and complains directly
about the volume of calls in a working day.[^calls-quiet]

This matters for the metric. The stated goal is GitHub stars in a Russian
*developer* ecosystem, so the adopter is a developer even when the payer is a
lead. A page that opens on decision hygiene is written for the person who
approves the invoice, not the person who stars the repo.

**Positioning, therefore:** not "better meetings" but *you did not have to be
there*. The tool reads the call so attendance becomes optional for the ones
where you were needed for five minutes out of sixty. What it must never claim is
that it can excuse you — that is a decision made by people, and a landing page
promising otherwise sells something it cannot deliver.

### 1.3 The pain is inside the calls, not around them

Searching in Russian for what actually goes wrong during developer calls returns
the Cruxwing thesis almost verbatim. Teams report that as the number of calls and
chats grows, real control of the project *falls*.[^calls-manage] Two recurring
failures:

- **Agreements live only in heads and chats** — the explicit recommendation in
  Russian practitioner writing is that договорённости must not stay in memory or
  in chat threads, but be recorded in structured form.[^calls-agreements]
- **Re-deciding**: having reached agreement and progress, teams find themselves
  going back and working through what was already worked through
  before.[^calls-agreements]

That second one is F1 — cross-meeting recall — described independently, in
Russian, by Russian practitioners. It is the strongest signal in this research
that the existing Cruxwing engine aims at a real Russian pain rather than a
translated American one.

Note what is *not* the pain: platform quality. SberJazz gives 100 participants
free with unlimited duration, TrueConf scales to 1500 in broadcast mode, and
SberJazz already ships automatic speech-to-text via SaluteSpeech into the
chat.[^vks] Competing on video plumbing is a losing move. Competing on *what the
call leaves behind* is not — a raw transcript dumped into a chat is precisely the
"agreement living in a chat" that the practitioners complain about.

---

## 2. Integration targets, ranked by what teams actually run

Russian teams did not standardise on one stack; the market is fragmented across
several credible trackers, which raises the value of a connector layer and lowers
the value of betting on any single one.

| Layer | Targets | Why this order |
|---|---|---|
| Task tracking | **Yandex Tracker** first, then **Kaiten** | Tracker already exposes an API and webhooks and integrates with GitHub/GitLab and messengers, so the connector has a documented surface; Kaiten is named alongside it as the Agile-team default.[^trackers][^tracker-api] |
| Task tracking (SMB) | WEEEK, YouGile, Planfix, Shtab | The small-team tier: YouGile is free to ten people with all features, Shtab has no headcount limit — this is where unfunded teams actually are.[^trackers][^trackers-smb] |
| Process/approvals | Pyrus | Different shape: built around заявки and согласования (leave, contracts, invoices), so it is a workflow target rather than a task target.[^trackers] |
| Calls | Yandex Telemost, VK Teams, SberJazz/SaluteJazz, TrueConf | The four repeatedly named as the domestic ВКС set.[^vks][^vks-alt] |
| Notes | Yandex Wiki (Yandex 360), Teamly | **ASSUMPTION** — not yet researched at first hand. |

**Architectural consequence.** Cruxwing's existing MCP connector layer is the
right substrate: each of these becomes a connector descriptor rather than a
special case, and the grounding deadline already in
`MCPConnectionManager.groundingDeadline` (8s — one wedged app costs one source
instead of the run) is exactly the latency discipline this brief asks for. The
blueprint work is therefore *connector descriptors + auth*, not new
architecture. Per-connector blueprints: next iteration.

---

## 3. Model strategy

The brief asks for Russian fluency at minimum viable cost. The evidence says
those two goals do not point at the same model, and the honest read is
uncomfortable for a "use a Russian model" instinct:

- On the Russian-language **MERA** benchmark, GigaChat 3.1 Ultra scores **0.712**,
  above GPT-5.2 at 0.707 and well above GPT-4o at 0.642.[^llm-compare]
- On **12 practical tasks** tested 2026-07-15, GigaChat and YandexGPT **did not
  win a single one**.[^llm-compare]

A benchmark win and a practical loss in the same month is the clearest possible
warning against picking a model from a leaderboard. It is the same mistake as
choosing a diarization threshold from three files — one this codebase has already
paid for (`cruxwing-app/docs/ROADMAP-RICE-2026H2.md`, findings 12 and 13).

**Decision for v1:**

1. **Open-weight first, Apache-2.0 by preference.** Qwen (3.6/3.7 series) is
   Apache 2.0 with strong multilingualism and tool use; DeepSeek V4 (MoE) is
   credible on price/quality.[^llm-oss] Permissive weights matter doubly here
   because the product itself ships open-source — a research-only licence in the
   default path would poison the repo's own promise.
2. **Domestic models as a routed option, not the default**, for teams whose
   requirement is data residency and local context — exactly the case where the
   comparison says they win.[^llm-compare]
3. **Own eval before adoption.** No model enters the default path on a published
   benchmark. The eval must be Russian *developer speech* — meeting audio with
   English technical terms inside Russian sentences — because that is the actual
   input, and it is not what MERA measures.

`RecallEmbedder` already routes by detected language, and the whole-file glossary
restore is measured WER-neutral, so the Russian path has existing bones. The
`DomainLexicon` will need a Russian-market vertical pack (banking/gov/telecom
acronyms) built under the same collision-audit rule that keeps ordinary words out.

---

## 4. Product shape

**Russian interface.** Not a translation layer bolted on: this branch ships
Russian-first. Two rules from the existing codebase carry over — the app must not
recase ordinary Russian words (the `GlossaryRestore` collision audit), and the
vowel set in garble detection already covers Cyrillic, without which every
Russian word reads as "vowelless" and becomes fair game for fuzzy repair.

**The wedge**, in one line: *the call is the source of truth, and orakul makes it
searchable in Russian.* Answering «что мы решили по ценам?» from your own past
calls is something no Habr thread and no Telegram chat can do, because the
material is yours.

---

## 5. Business model — бесплатно, целиком

Решение владельца: платных уровней нет. Не «пока не назначены цены», а нет
вообще — тарифы, платные кнопки и разграничение по подписке удалены из продукта,
из каталога, со страницы и из кода.

Это не только про деньги. Граница проходила по инфраструктуре: бесплатно то, что
считается на компьютере пользователя, платно то, за что платим мы. Убрав вторую
половину, продукт получает свойство, которое раньше приходилось обещать словами:
**всё работает без сети, потому что ничего другого просто нет**. Кнопка,
требующая сети, теперь не грузится — не по вкусу, а потому что каталог с ней
не проходит проверку при сборке.

Что удалено:

- `config/plans.ru.json` и его тесты — каталог уровней;
- кнопки `to-tracker` и `week-digest` — единственные, которым нужен наш сервер;
- поле `tier` у кнопок — место, где платный уровень отрастает обратно;
- `PromptCatalog.Tier`, `available(for:)`, `unavailabilityReason(...)` —
  механизм разграничения, которому больше нечего разграничивать;
- раздел «Тарифы» на странице.

Метрика прежняя: звёзды и установки. Она стала честнее — у репозитория, где
нечего продавать, README и есть весь маркетинг.

**Что это стоит.** Коннекторы к трекерам и сводка недели были обоснованием
платного уровня; вместе с ним ушли и они. Это сознательный размен: продукт,
который целиком работает на устройстве, проще обещать и невозможно испортить
тихим переносом функции за платную стену.

---

## 6. Russian ASR on developer speech — the top risk, now measured by others

This was named the highest technical risk in v1 because every downstream feature
reads the transcript. The research changes the risk from unknown to *known and
addressable*, with one large caveat about how it is usually measured.

### 6.1 The published numbers are not measured on speech like ours

GigaAM's headline **3.3% WER on CPU** — reported as 2.4× better than Whisper
large-v3-turbo on an RTX 4090 — was measured on **TTS fragments from
audiobooks**, and conclusions shifted once real production recordings were
used.[^asr-gigaam] Clean-speech accuracy for the best Russian systems is
**95–98%**, but real conditions (noise, interruptions, accents, rare terms) are
explicitly called out as where that falls apart.[^asr-accuracy]

An audiobook is the one input a meeting never is: one speaker, no interruption,
studio audio, no jargon. This is the same fixture-versus-reality trap already
paid for twice in this codebase — the diarization threshold chosen from three
files, and the speaker-count metric that was uncorrelated with attribution
(`cruxwing-app/docs/ROADMAP-RICE-2026H2.md`, findings 12–13). **No ASR model
enters the default path on a published WER.**

### 6.2 Code-switching is the specific failure, and we already built for it

Russian developers do not speak Russian. They speak Russian with English
technical terms inside the sentence, and that is a named ASR failure mode:
mixing languages leaves parts of the recording unidentifiable, and algorithms do
poorly on narrow technical terms absent from their training
data.[^asr-codeswitch]

This is precisely the case `GlossaryRestore` exists for. The decoder-prompt
glossary was measured harmful at scale (term recall bought by deleting speech —
WER 0.95 with 2757 deletions on the large tier), so the whole-file pass decodes
with **no glossary at all** and vocabulary is restored afterwards as text, where
a mistake can only touch one token and can never make speech disappear. The
architecture answering the top risk is already written and measured.

### 6.3 Whole file, not chunks

VAD chunking physically segments speech and causes hallucinations and word loss
at segment boundaries; complete audio is recognised **better than the sum of its
parts**.[^asr-gigaam] Cruxwing's whole-file post-call pass is therefore the right
shape and must not be "optimised" into chunked decoding.

### 6.4 Измерено нами, на русской речи разработчиков

Первое собственное измерение, а не чужой бенчмарк. Корпус: три фрагмента
русского доклада по AI-безопасности (`cruxwing-api/data/russian`), расшифрованные
тремя движками — Whisper large, Parakeet, Fireflies. Эталона, размеченного
человеком, нет, поэтому WER не считался; считалось расхождение движков между
собой, потому что разногласие само по себе доказывает ошибку.

| фрагмент | терминов прозвучало | спорных | согласие |
|---|---|---|---|
| w900 | 4 | 2 | 50% |
| w2700 | 8 | 1 | 88% |
| w4300 | 4 | 1 | 75% |
| **среднее** | | | **71%** |

Whisper и Parakeet расходятся на **11–14% слов**. На фрагменте w2700 у Parakeet
57 пропусков против 3 вставок — движок не ошибается, а молчит, и это ровно та
болезнь, которую суммарный WER не отличает от искажения.

**Спорные термины — это в точности код-свитчинг:** «прод», «промпт», «API»,
«джейлбрейк». Русские фразы с английскими корнями, ровно там, где исследование
и предсказывало провал.[^asr-codeswitch] Ни один спорный термин не оказался
обычным русским словом.

Вывод для продукта, и он подтверждает архитектуру: чинить это в декодере
бессмысленно — термин, которого модель не слышала, она не расслышит и с
подсказкой. Чинится это после расшифровки, текстом, где ошибка стоит одного
токена и не может съесть речь. То есть `GlossaryRestore` с русским словарём —
не «улучшение», а основной механизм для этого рынка.

### 6.5 Candidate models

| Model | Why it is a candidate | Caveat |
|---|---|---|
| **T-one** (T-Bank) | 70M params, streaming, and reported to lead open models on **noisy, compressed call-centre Russian** — beating GigaAM v2 (242M) and Whisper large-v3 (1.5B) on internal benchmarks[^asr-tone] | "Internal benchmarks"; call-centre audio is closer to a meeting than an audiobook, but is still not a meeting |
| **GigaAM** | Strong Russian numbers, CPU-viable | Headline figure from audiobook TTS[^asr-gigaam] |
| **Whisper** (current engine) | Already shipped, multilingual, handles code-switching by design | Beaten on Russian by both above, on their own benchmarks |

**Decision:** T-one is the first model to evaluate, on our own corpus, against
shipped Whisper. Streaming at 70M parameters is the right shape for on-device.
The eval set must be *Russian developer meeting speech with English terms*, and
it must be built before any model is adopted — the corpus is the deliverable, not
the model choice.

---

## 7. Отдельное приложение, и почему Windows идёт первым

**orakul — не сборка Cruxwing под другим именем.** Идентичность разведена
полностью (`config/app.json`, проверяется `test/identity.test.mjs`): bundle id
`ai.orakul.desktop` против `com.meetgpt.macapp`, свой том установщика, свой
набор настроек и своя служба в Связке ключей.

Это не косметика. macOS привязывает разрешение на запись экрана и микрофона к
bundle id: при совпадении две программы делят один доступ, и отозвать его у
одной, не забрав у второй, нельзя. Общий `UserDefaults` suite означал бы, что
установка orakul меняет настройки Cruxwing на той же машине. Установщики
называются `orakul-*` и складываются в собственный каталог — файл с именем
Cruxwing не может быть перезаписан и наоборот.

### Windows: не «потом», а, возможно, вперёд macOS

Cruxwing — нативное приложение macOS: захват через ScreenCaptureKit, модели
через CoreML. На российском рынке это ограничение бьёт сильнее, чем на
американском: корпоративный парк здесь преимущественно Windows, и продукт для
разработчиков, доступный только на Mac, отсекает большую часть аудитории до
первого запуска. **ASSUMPTION** — доля macOS среди российских разработчиков не
измерена, и это следующий вопрос к исследованию; но направление ошибки понятное.

Что реально стоит порт (честная оценка, а не «перекомпилировать»):

| Слой | macOS сегодня | Windows |
|---|---|---|
| Захват системного звука | ScreenCaptureKit | **WASAPI loopback** — другая реализация целиком |
| Расшифровка | CoreML | ONNX Runtime / whisper.cpp — модель та же, рантайм другой |
| Поиск по встречам, глоссарий, ответы с цитатой | общий код | **переносится без изменений** |
| Интерфейс | SwiftUI | отдельный слой |

Ядро — то, ради чего продукт существует, — платформенно-независимо. Платформенны
захват и оболочка. Это делает Windows дорогим, но не «вторым продуктом»: граница
проходит там же, где она уже проходит в коде.

---

## 8. Telegram: фрагментация, у которой есть число

Телеграм — фактическая замена форуму, и его беда структурная, а не культурная.
Все источники сведены в одну ленту чатов, поэтому найти нужное трудно
by design.[^tg-search] Масштаб виден по чужой попытке починить это: автор
проекта «StackOverflow из IT-чатов Telegram» вручную вступил примерно в **250
тематических чатов** и отдельным сервисом отфильтровывал сообщения-вопросы из
общего потока.[^tg-so] Инструментов-поисковиков по каналам (Teleteg, TGStat) и
каталогов (TLGRM) хватает — то есть проблему признают все, и решают её снаружи,
поиском по чужим чатам.[^tg-search]

**Вывод для orakul, и он ограничивающий.** Соблазн — «сделать поиск по
телеграм-чатам». Это ошибка по трём причинам: чужие чаты не наш контент, ответ в
чате не имеет статуса решения, и рынок таких поисковиков уже есть. Ценность
orakul в обратном: **не искать ответ у посторонних, а находить его в своих
созвонах**, где он уже прозвучал и где у него есть автор и дата. Телеграм в
продукте появляется как источник контекста для собственной команды (свои чаты,
по явному подключению), а не как поисковый индекс по экосистеме.

---

## 9. Интеграция с GitHub (черновик архитектуры)

Метрика проекта — звёзды и установки, поэтому GitHub здесь не «ещё один
коннектор», а витрина. Две разные вещи, которые нельзя путать:

**9.1. Репозиторий как продукт.** Открытое ядро под Apache 2.0. Что решает
судьбу звезды: README, который запускается с первого раза, и понятная граница
между открытым и платным. Правило: всё, что обрабатывает речь пользователя, —
открыто; закрыто только то, что работает на нашей инфраструктуре.

**9.2. GitHub как источник контекста.** Связывает созвон с кодом: обсуждение
«давайте вынесем биллинг в отдельный сервис» и PR, который это делает, — одно
решение в двух местах.

| Что | Как | Почему так |
|---|---|---|
| Чтение issues/PR | GitHub REST + MCP-коннектор | Тот же слой, что и трекеры: коннектор, а не частный случай |
| Привязка решения к PR | по номеру и по названию ветки, произнесённым на созвоне | Номер PR в речи — самый надёжный якорь; распознаётся как цифра, а не термин |
| Запись обратно | черновик комментария, отправляет человек | Правило продукта: сам он не отправляет ничего |
| Приватность | только по явному подключению репозитория | Код не уходит в модель без отдельного согласия |

**Задержка.** Тот же дедлайн, что у остальных коннекторов (8 с): один
подвисший источник стоит одного источника, а не всего ответа.

---

## 10. What is still unknown

1. ~~Telegram dev-chat structure~~ — researched in §8. Remaining unknown is
   narrower: whether teams would connect their OWN work chats as a context
   source, which is a privacy question, not a search question.
2. Willingness to pay, and where the tier boundary sits.
3. Note-taking tool landscape (marked ASSUMPTION above).
4. ~~Whether Russian ASR quality on developer speech is good enough~~ —
   researched in §6. Downgraded from unknown to a build task: assemble a Russian
   developer-meeting eval corpus, then measure T-one against shipped Whisper on
   it. Still the top risk, but now a measurable one.

[^tg-search]: [Эффективный поиск в Telegram — Perfluence](https://perfluence.net/blog/article/kak-najti-nuzhnoe-v-telegram-rukovodstvo-dlya-prodvinutyh-polzovatelej)
[^tg-so]: [Я сделал StackOverflow из IT-чатов Telegram — Хабр](https://habr.com/ru/articles/574666/)
[^asr-gigaam]: [Как я снизил WER с 33% до 3.3% для русской речи на CPU: сравнение GigaAM, Whisper и Vosk — Хабр](https://habr.com/ru/articles/1002260/comments/); [Whisper или GigaAM для русского ASR в продакшене: три ловушки бенчмарка — Хабр](https://habr.com/ru/articles/1042574/)
[^asr-tone]: [Обгоняет GigaAM и Whisper: «Т-Банк» опубликовал T-one — iXBT](https://www.ixbt.com/news/2025/07/22/gigaam-whisper-t-one.html); [Бенчмарк качества ASR в телефонии — Хабр](https://habr.com/ru/articles/938438/)
[^asr-codeswitch]: [Технология распознавания речи: как она работает — Skillfactory](https://blog.skillfactory.ru/kak-rabotaet-tehnologiya-raspoznavaniya-rechi/)
[^asr-accuracy]: [Система распознавания речи: как работает ASR — Gravitel](https://gravitel.ru/blog/biznes/sistema-raspoznavaniya-rechi/)
[^so-decline]: [Stack Overflow умирает? Как ИИ вытесняет живые сообщества разработчиков — Хабр](https://habr.com/ru/companies/ru_mts/articles/912160/)
[^so-mod]: [Убивают ли LLM сайт StackOverflow? — Хабр](https://habr.com/ru/articles/875760/); [Почему умирает Stack Overflow — Skillbox Media](https://skillbox.ru/media/code/pochemu-umiraet-stack-overflow-i-kuda-teper-idti-za-otvetami/)
[^qna]: [Как правильно оформить вопрос на QNA.Habr — Хабр Q&A](https://qna.habr.com/q/1391680); [Правила — Хабр Q&A](https://qna.habr.com/help/rules)
[^calls-quiet]: [Продуктивность в тишине: Отказ от совещаний как идеал — Хабр](https://habr.com/ru/articles/800645/); [Сколько раз в неделю – норма? О производственных совещаниях — Хабр](https://habr.com/ru/articles/834136/)
[^calls-manage]: [Как не бесить разработчиков и чётко управлять проектом](https://www.novostiitkanala.ru/news/detail.php?ID=196819)
[^calls-agreements]: [Про звонки и совещания — vc.ru](https://vc.ru/dev/1997848-effektivnye-zvonki-i-soveshchaniya-v-komande); [Созвоны, аватарки и немного тревожности — Хабр/YADRO](https://habr.com/ru/companies/yadro/articles/1062334/)
[^vks]: [Видеоконференции SberJazz](https://sberjazz.ko.ru/); [ТОП-13 платформ ВКС 2026 (on-premise)](https://iaassaaspaas.ru/rating/vks/on-premise-2026)
[^vks-alt]: [Аналоги Zoom в 2026 году — express.ms](https://express.ms/blog/obzory/alternativy-zoom-obzor-rynka-videosvyazi-v-2026-godu/)
[^trackers]: [ТОП-9 российских таск-трекеров в 2026 году — Хабр/Directum](https://habr.com/ru/companies/directum/articles/971170/)
[^tracker-api]: [Что умеют таск-трекеры в 2026 году — Хабр/YouGile](https://habr.com/ru/companies/yougile/articles/1023944/)
[^trackers-smb]: [Российские таск-трекеры в 2026: обзор рынка](https://sdelanounas.ru/blogs/175219/)
[^llm-compare]: [Сравнение отечественных LLM 2026 — AZONE-AI](https://azoneai.ru/blog/10-sravnenie-llm/); [Чем заменить ChatGPT в России в 2026 — autollab](https://autollab.ru/blog/chem-zamenit-chatgpt-v-rossii-2026)
[^llm-oss]: [Лучшая LLM для русского языка 2026 — ofox.ai](https://ofox.ai/ru/blog/luchshaya-llm-dlya-russkogo-yazyka-sravnenie-2026/)
