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

**Измерено нами 2026-08-13, а не взято из чужого обзора.** Первая страница
ленты новых вопросов Хабр Q&A — двадцать штук — покрывает **семь дней**: от «8
минут назад» до 6 августа.[^qna-new] Это меньше трёх вопросов в сутки на весь
русскоязычный IT-сервис вопросов и ответов. Для сравнения: у Stack Overflow на
пике счёт шёл на тысячи в день.

Состав ленты важнее объёма. Из двадцати вопросов к разработке программ
относятся семь: axis в Pandas, выборочное копирование колонок со страницы,
автообновление при выборе option, react против его фреймворков, редактируемые
поля, дублирование select в Firefox, ChatGPT как репетитор по архитектуре.
Ещё семь — сети и администрирование (VPN, 3X-UI, Asterisk, RDS, ядро), шесть —
общая техподдержка: «Что это за разъём Wi-Fi?», «Как исправить прилипание
крышки MacBook Air M1?». То есть вопросов по разработке — около одного в сутки.

Лента вопросов без ответа даёт вторую половину картины: на её первой странице
рядом с вопросом восьмиминутной давности лежат вопросы от 2 июля.[^qna-noanswer]
Полтора месяца без ответа — и это не хвост архива, а первая страница.

**Оговорка, без которой число врёт:** это один замер одного дня и только первых
страниц двух лент. Не временной ряд и не выборка по всему сайту. Проверяется
руками за минуту по двум адресам в сносках — и на том стоит.

**Модерация: бриф спрашивал про предвзятость, и она называется конкретно
(прочитано 2026-08-13).** Не по чужим обзорам, а в обсуждении собственных
правил Хабра 2026 года — там авторы спорят с модерацией прямо.[^habr-rules]
Претензии повторяются и все три про одно: решение принимает кто-то другой, и
оспорить его нечем.

| Механизм | В чём претензия |
|---|---|
| Карма | «можно под любым предлогом убрать карму человеку в минус» — и оспорить нельзя |
| Избирательность | правила про политику применяют к обычным пользователям, но не к корпоративным блогам |
| Непрозрачность | человек не видит, какой именно комментарий стоил ему кармы |

Формального порядка обжалования нет: обращения в поддержку остаются без ответа
по словам самих комментаторов.

**Почему это важно именно нам.** Претензия здесь не «модераторы злые», а
«статус ответа зависит от чужого решения, которое не объяснено и не
оспаривается». Ровно этого нет у ответа из собственного звонка: у него есть
автор, дата и запись, и никакой третьей стороны, которая может его снять. Это
не «форум, но добрее» — это другой источник правды.

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

### 1.4 Быстрый старт пройден из чистого клона (2026-08-13)

Всё, что обещают README и CONTRIBUTING, выполнено по написанному в пустой
папке, а не «должно работать».

| шаг | результат |
|---|---|
| `git clone` | клон полный, лишнего соседнего репозитория не требует |
| `cd mvp && swift build -c release` | 73 с |
| пример с расшифровкой | вывод совпал с README дословно, включая строку ответа; отказ на несуществующем вопросе — тоже дословно |
| `cd app && swift build` | 176 с, скачано 27 пакетов, ошибок нет |
| `cd app && swift test` | 2654 пройдено, 11 пропущено (нужны настоящие модели, записи, живой сервис) |
| `cd mvp && swift test` | 294 пройдено |
| `npm test` | 158 проверок, 154 пройдено, 4 пропущено с указанной причиной — им нужен соседний репозиторий автора |

Разошлось одно место, и оно исправлено: у `app/` четыре прямые зависимости, но
сборка печатает **27** строк `Fetching`. «Четыре» рядом с наблюдаемыми
двадцатью семью читается как заниженное число.

Смысл замера не в том, что всё сошлось. Смысл в том, что до него это было
предположением: набор тестов проверяет код, а не то, выполнимы ли строки из
README на машине, где ничего нет.

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
| Notes | Yandex Wiki (Yandex 360), Teamly | Проверено 2026-08-11: подключить сейчас нельзя ни один — см. §2.1. |

### 2.0 Открытое, что команда поднимает у себя (проверено 2026-08-12)

Вывод §2.1 ниже — про российские облака, и он в силе. Но он не про открытые
сервисы, которые команда разворачивает на своём сервере: там поиск по тексту
есть, и подключение упирается только в поле «адрес сервера».

| Сервис | Запрос | Особенность |
|---|---|---|
| Mattermost | `POST /api/v4/teams/{id}/posts/search` | `is_or_search: false` — И, а не ИЛИ |
| Rocket.Chat | `GET /api/v1/chat.search?roomId=` | нужны ДВА значения: токен и user-id |
| Zulip | `GET /api/v1/messages?narrow=[{"operator":"search"}]` | Basic-авторизация `почта:ключ` |
| Matrix / Element | `POST /_matrix/client/v3/search` | тело с `search_categories.room_events` |
| GitLab | `GET /api/v4/search?scope=issues&search=` | заголовок `PRIVATE-TOKEN` |
| Gitea / Forgejo | `GET /api/v1/repos/issues/search?q=&type=issues` | `Authorization: token`, не `Bearer` |
| Redmine | `GET /search.json?q=&issues=1` | единственный оборачивает выдачу в `results` |
| Битрикс24 | `POST /rest/{id}/{код}/tasks.task.list` | ключ в адресе, а не в заголовке; список под `result.tasks`, поля прописными; страница всегда 50; **отказ приходит с HTTP 200** и полями `error`/`error_description` |
| Outline | `POST /api/documents.search` | адрес НЕ обязателен — бывает облачным |

Две детали закреплены тестами, потому что по тексту ошибки их не восстановить:
Gitea со словом `Bearer` отвечает 401, неотличимо от плохого токена;
Rocket.Chat без `roomId` возвращает пустой список, неотличимо от «ничего не
нашлось».

**Outline закрывает то, что §2.1 оставлял пустым.** Раздел заметок был закрыт
как невозможный — и для Яндекс Вики с Teamly это по-прежнему так. Но открытая
вики на своём сервере отдаёт `context` — готовый кусок текста вокруг совпадения,
то есть ровно то, что нужно подсказке: не ссылку, а слова.

#### 2.0.0 Адрес сервера: где путь срезается, а где нет (решено 2026-08-13)

Три семейства коннекторов обходятся с вставленным адресом по-разному, и это
решение, а не недосмотр.

| Кто | Путь из адреса | Почему |
|---|---|---|
| Kaiten | срезается | подсказка ведёт на доску, человек копирует `.../boards/5`, и с `/api/latest` это 404 без объяснения. Так и было |
| Битрикс24 | разбирается целиком | вебхук показывают одной строкой, и в ней же лежит ключ (§2.0.1) |
| GitLab, Gitea, Redmine, мессенджеры | сохраняется | их ставят в подкаталог (`company.ru/gitlab`); срезание сломало бы рабочую настройку |

Соблазн — «выровнять поведение». Он неверен: у Kaiten срезание чинит
наблюдавшуюся ошибку, у своих серверов оно ломало бы работающее ради ошибки,
которой мы не видели, — их подсказка просит адрес сервера, а не адрес страницы.
Разница закреплена `HostNormalisationPolicyTests`, чтобы тот, кто решит
выравнивать, сначала увидел, что теряет.

### 2.0.1 Битрикс24: сделано по документации, не по живому порталу (2026-08-13)

Коннектор к Битрикс24 написан и закрыт тестами, но **на настоящем портале не
проверен** — портала с вебхуком у нас нет. Это отличается от трёх остальных
трекеров и от правила «не заявляйте того, чего нет» ровно на одну вещь: здесь
проверена документация вендора, а не ответ сервера.

Что взято из документации метода `tasks.task.list`: адрес
`POST /rest/{id_пользователя}/{код_вебхука}/tasks.task.list`, поиск по `TITLE`
шаблоном со знаками `%` и `_` **в значении**, ответ `{"result": {"tasks": []}}`,
размер страницы всегда пятьдесят и параметром не задаётся.

Одно место осталось неоднозначным. Общий приём Битрикса для поиска по подстроке
— приставка к имени поля (`%TITLE`), но в документации именно этого метода
показан шаблон в значении. Реализовано то, что описано; если живая проверка
покажет обратное, менять одну строку в `body(for:limit:)`.

**Как проверить за одну команду,** когда портал есть:

```bash
cd app && ORAKUL_PROBE_SERVICE=bitrix24 ORAKUL_PROBE_TOKEN='1/код' \
  ORAKUL_PROBE_HOST=фирма.bitrix24.ru ORAKUL_PROBE_QUERY=тариф \
  swift test --filter LiveConnectorProbe
```

### 2.0.2 Мегаплан: отпадает по тому же правилу (проверено 2026-08-13)

Мегаплан стоял в списке ожидаемых трекеров и не проходит ту же проверку, что
сняла два сервиса раньше.

- **Долгоживущего ключа нет.** Токен берётся обменом логина и пароля:
  `POST /api/v3/auth/access_token`, `grant_type=password`. Приложению, чтобы
  обновлять токен, пришлось бы держать пароль от рабочего аккаунта. Для
  продукта, у которого секреты живут в Связке ключей именно затем, чтобы
  пароля нигде не было, это не мелкая неудобность, а смена условий.
- **Описание методов закрыто аккаунтом.** Публичная страница прямо говорит:
  описание всех методов и сущностей — внутри Мегаплана, по пути
  `/api/v3/docs`.[^megaplan] То есть параметр поиска задач, форму фильтра и
  форму ответа проверить снаружи нельзя, а правило CONTRIBUTING требует
  проверить их до кнопки.

**Что изменит вывод:** появление ключа приложения без пароля пользователя, или
публичное описание метода списка задач. Тогда это обычная работа на день.

### 2.0.3 Трекеры: перепись целиком (проверено 2026-08-13)

Обход списка закончен. Восемь сервисов, четыре подключены, четыре нет — и у
каждого «нет» названа причина, а не «руки не дошли».

| Сервис | Состояние | Чем решено |
|---|---|---|
| Яндекс Трекер | подключён | OAuth-токен и идентификатор организации; заголовок выбирается по форме идентификатора (§2.2) |
| Kaiten | подключён | токен из профиля, адрес команды свой у каждой |
| YouGile | подключён | ключ компании, общий облачный адрес |
| Битрикс24 | подключён **по документации**, не на живом портале | вебхук в пути; §2.0.1 — команда для живой проверки |
| Pyrus | нет | другая форма продукта: заявки и согласования, не задачи (§2) |
| WEEEK | нет | описание метода списка задач снаружи не читается: справочник на `developers.weeek.net` отдаётся скриптом, страница аутентификации есть, страницы метода — нет. Перепроверено 2026-08-13 |
| Мегаплан | нет | нет долгоживущего ключа, вход логином и паролем; описание методов — внутри аккаунта (§2.0.2) |
| Аспро.Cloud | нет | публичного описания методов найти не удалось: на `aspro.cloud/api/` страница о том, что API есть, без справочника[^aspro] |

Про Аспро формулировка узкая намеренно: **не «API нет», а «справочника снаружи
не нашли»**. Если у кого-то есть аккаунт и он покажет метод списка задач, его
параметр поиска и форму ответа — это работа на день, как и с WEEEK.

Общее у четырёх отказов одно: правило «не заявляйте того, чего нет» проверяется
до кнопки, а не после жалобы. Два сервиса выпали на этой проверке ещё в первом
обходе, и это правильный исход, а не потеря.

## 2.1 Заметки: почему коннектора нет (проверено 2026-08-11)

Строка про заметки год стояла с пометкой «предположение». Проверка по
документации вендоров показала, что предположение было неверным в важной части:
доступ к API есть, а нужного нам метода — нет.

**Яндекс Вики.** База `https://api.wiki.yandex.net`, авторизация ровно как у
Яндекс Трекера: `Authorization: OAuth <токен>` плюс `X-Org-Id`. Задокументирован
`GET /v1/pages?slug=…` — страница по адресу. Полнотекстового поиска в публичной
справке нет: обзорная страница обещает «искать страницы по тексту с помощью
методов API», но самого метода, его параметров и формы ответа в открытой
документации не приводится.

**Teamly.** Публичного описания API найти не удалось — только материалы про
продукт и его собственный ИИ-поиск.

**Вывод.** Коннектор к заметкам не пишется, пока не подтверждён метод поиска.
Взять `GET /v1/pages?slug=` и назвать это поиском нельзя: он находит страницу,
адрес которой уже известен, то есть отвечает на вопрос, которого у пользователя
нет. Из тех же соображений выпали WEEEK и Pyrus (см. заголовок файла
`RussianTrackers.swift`), и это дешевле, чем кнопка, которая молчит.

Что разблокирует работу: доступ к организации в Яндекс 360, где метод поиска
можно вызвать и увидеть ответ. До этого — строка «Заметки» остаётся в списке
несделанного, а не в списке интеграций.

### 2.2 Чертёж коннектора (как сделано, а не как задумано)

Три трекера уже написаны, поэтому чертёж описывает работающий код —
`mvp/Sources/OrakulCore/RussianTrackers.swift` и его хранилище. Новый коннектор
повторяет эту форму; отклонение от неё требует причины в комментарии.

**1. Три поля вместо одного.** Токена почти никогда не хватает, и не хватает
по-разному:

| Поле | Зачем | Пример |
|---|---|---|
| токен | доступ | OAuth-токен Яндекса, API-ключ Kaiten |
| второе поле | без него запрос уходит не туда | `X-Org-Id` у Яндекса, домен команды у Kaiten |
| место назначения | куда класть заведённую задачу | очередь `TREK`, доска `4`, колонка |

Подпись каждого поля живёт рядом с кодом, который это поле использует
(`secondaryPrompt`, `destinationPrompt`), а не в интерфейсе: в интерфейсе она
разъезжается с назначением при первой же правке.

**2. Чтение и запись — разные права.** `isConfigured` разрешает спрашивать,
`canFileTasks` — заводить. Трекер, подключённый только на чтение, это нормальное
состояние, а не недоделанное: место назначения нужно лишь для записи.

**3. HTTP приходит снаружи.** `RussianTrackers.HTTP` — замыкание, у продакшена
`live` на `URLSession`, у теста своё. Значения по умолчанию в инициализаторе нет
намеренно: забытый аргумент в тесте иначе молча пошёл бы в чужой сервис.

**4. Дедлайн 8 секунд** — тот же, что у MCP-источников. Один зависший сервис
стоит одного источника, а не всего ответа. Это и есть требование брифа про
низкую задержку, выраженное числом.

**5. Ошибки различимы.** `notConfigured` / `unauthorised` / `http(код)` /
`vendor(код, описание)` / `unreadable`. Разница не косметическая: первое
чинится в настройках, второе — новым токеном, третье — ожиданием, четвёртое
пересказывает слова самого сервиса, пятое означает, что сервис сменил формат и
коннектор пора править.

**5.1. Успех не значит согласие.** Битрикс24 отвечает `200` и кладёт отказ в
тело: `{"error": …, "error_description": …}`. Коннектор, который смотрит только
на код ответа, покажет отозванный вебхук как «задач не нашлось». Проверять тело
до разбора списка — правило, а не частность Битрикса: так же ведут себя многие
корпоративные API.

**5.2. Пустой список — только знакомой формы.** Ответ без единого известного
ключа — отказ, а не «ничего нет». `[]` и `{"content": []}` проходят, потому что
форма узнана и строк ноль; `{"detail": "…"}` — нет. Разница решает, заведёт ли
человек вторую задачу поверх существующей.

**6. Мягко читаем, строго пишем.** В выдаче поиска задача без заголовка
показывается как «Без названия» — одна кривая запись не стоит всей выдачи. При
создании наоборот: ответ без ключа задачи — это ошибка, а не успех. Сказать
«задача заведена», когда её нет, — худшее, что коннектор может сделать.

**7. Подсказка вместо голой цели.** В трекер уходит не «что мы решили по
срокам», а цель плюс `ConnectorProbeStrategy.trackerProbe.queryHint`: их
ранжирование опирается на слова из задач.

**7.1. Учётные данные не обязаны ехать в заголовке.** У Битрикса вебхук —
это путь: `/rest/{id}/{код}/метод`. Отсюда два следствия. Первое: общая
проверка «ключ уехал» не должна требовать заголовка — иначе сервис либо
выпадает из проверки, либо ему придумывают заголовок, которого вендор не ждёт.
Второе: адрес такого сервиса нельзя показывать в сообщении об ошибке — в нём
лежит ключ.

**7.2. Размер страницы не всегда наш.** У Битрикса он всегда пятьдесят и
параметром не задаётся, поэтому запрошенная граница применяется после разбора.
Молча вернуть пятьдесят там, где просили десять, — тихо раздуть подсказку и
съесть чужие источники из общего бюджета.

**8. Ничего не заявляем без документации вендора.** Метод, адрес, параметр
поиска и форма ответа проверяются в справке вендора и указываются в
комментарии. На этом правиле отсеялись WEEEK, Pyrus и обе базы знаний — и это
дешевле, чем кнопка, которая не срабатывает.

**Architectural consequence.** Cruxwing's existing MCP connector layer is the
right substrate: each of these becomes a connector descriptor rather than a
special case, and the grounding deadline already in
`MCPConnectionManager.groundingDeadline` (8s — one wedged app costs one source
instead of the run) is exactly the latency discipline this brief asks for. The
blueprint work is therefore *connector descriptors + auth*, not new
architecture. Per-connector blueprints: next iteration.

---

## 2.3 Приложение задач в трекер: что позволяют API (проверено 2026-08-11)

Чтение из трекера уже работает. Обратный путь — завести задачу из решения,
принятого на звонке, — упирается в то, что каждому сервису нужен адрес
назначения, и он у всех разный:

| Сервис | Метод и путь | Обязательные поля |
|---|---|---|
| Яндекс Трекер | `POST /v3/issues/` | `summary`, `queue` (ключ очереди, например `TREK`) |
| Kaiten | `POST /api/latest/cards` | `title`, `board_id` (целое) |
| YouGile | `POST /api-v2/tasks` | `title`; `columnId` — колонка, куда положить |

Отсюда следует устройство настройки: одного токена мало. Кроме второго поля
(организация у Яндекса, домен команды у Kaiten) нужно третье — куда именно
класть задачу. Без него кнопка «Завести задачу» была бы кнопкой, которая
отправляет запрос в никуда, а ответ об ошибке пришёл бы уже после звонка.

Про YouGile документация расходится: `columnId` местами помечен необязательным.
Мы всё равно требуем его — задача без колонки не попадает на доску, то есть
пропадает с точки зрения пользователя, а лишний валидный параметр никогда не
ошибка.

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

### 3.0 GigaChat: не оценка модели, а хранилище доверенных корней (проверено 2026-08-13)

GigaChat в списке провайдеров orakul нет, и причина не в качестве. С обычного
macOS до него не доходит TLS: цепочка заканчивается корнем Минцифры, которого
в системном хранилище нет.

Замер `curl`, 2026-08-13:

| адрес | `ssl_verify_result` | что это значит |
|---|---|---|
| `ngw.devices.sberbank.ru:9443` (обмен ключа на токен) | 19 | самоподписанный сертификат в цепочке |
| `api.giga.chat` (OpenAI-совместимый) | 20 | локально не найден издатель |

Цепочка первого: `CN=ngw.devices.sberbank.ru` → `Russian Trusted Sub CA` →
`Russian Trusted Root CA` (The Ministry of Digital Development and
Communications).

**Почему это решает вопрос.** Кнопка «Подключить», которая падает с «сертификат
сервера недействителен», хуже отсутствующей кнопки — правило из CONTRIBUTING.
Ставить корневой сертификат за человека приложение не должно и не будет: это
изменение доверия всей системы, а не настройка одного продукта.

**Что изменит вывод.** Пользователь, поставивший корень Минцифры сам, получает
рабочий OpenAI-совместимый адрес `https://api.giga.chat/v1` с Bearer-токеном.
Токен там живёт тридцать минут и берётся обменом ключа на `/api/v2/oauth` —
это не статический ключ, как у остальных восьми провайдеров, и потребует
отдельной ветки обновления. Если корень появится в macOS по умолчанию или
Сбер выпустит цепочку от общедоверенного центра, эта заметка устаревает.

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

### 3.1 Ключ провайдера вводит пользователь (сделано)

Из решения «сервера нет» следует то, о чём легко забыть: в готовом установщике
ключей провайдеров нет ни одного — их туда не кладут намеренно, — а значит без
пользовательского ключа приложение не отвечает вообще. Скачанное приложение,
которое не может ответить ни на один вопрос, — это не бесплатный продукт, а
неработающий.

У Cruxwing ввод ключа убрали, когда появился серверный шлюз: ключи уехали на
сервер, `Secrets` стал пустым. orakul унаследовал этот код без шлюза, то есть
худшую половину решения.

Поэтому `ProviderKeyStore`: ключ вводится в «Настройки → ИИ → Ключи
провайдеров», лежит в Связке ключей, и при запросе он важнее зашитого при
сборке. Порядок именно такой — обратный означал бы, что ключ из чужого `.env`,
случайно попавший в сборку, молча переопределяет тот, который человек только
что вписал и видит на экране.

Побочный, но важный эффект для позиционирования: расход идёт по договору
пользователя с провайдером. Нам не за что брать деньги, потому что мы не стоим
в этой цепочке, — и это то же самое основание, по которому в продукте нет
тарифов.

Порядок провайдеров в списке: сначала DeepSeek, Qwen, GLM, Kimi, потом OpenAI,
Anthropic, Google. Основание — ожидаемая цена запроса, и только она. Про Qwen и
DeepSeek выше есть ссылки; про GLM и Kimi своих измерений мы не проводили, и
раньше здесь стояло «дешевле при приемлемом русском» — оценка качества, которую
никто не проверял. Порядок в списке её не заменяет.

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

**Одна форма ошибки повторяется чаще всех остальных вместе взятых.** Не
падение и не неверный расчёт, а *уверенная фраза о том, чего не было*. За одну
ночь она нашлась семь раз, и каждый раз выглядела как исправная работа:

| что человек видел | что произошло на самом деле |
|---|---|
| «В сохранённых звонках об этом не говорили» | архив пуст, звонков нет вовсе |
| то же | часть файлов архива не открылась, их не искали |
| то же | в вопросе одни служебные слова, поиск не запускался |
| «Удалено: <идентификатор>» | такой встречи не существовало |
| десять задач из трекера | их сорок семь, показаны первые десять |
| «Трекер ответил непонятным образом» | сервер внятно ответил 502 |
| `[#314, unknown]` | сервис состояния не сообщал, его выдумали |

Общее у всех семи: продукт утверждал результат операции, которой не
происходило. Для инструмента, чьё единственное обещание — «отвечает цитатой и
не выдумывает», это и есть главный класс дефектов: он не ломает работу, он
тихо подменяет её. Тесты его не ловят, потому что код делает ровно то, что
задумано; ловится он только запуском собранного продукта и вопросом «а это
правда?» к каждой уверенной фразе.

Отсюда правило для новых сообщений: **если фраза утверждает исход, найдите
случай, когда исхода не было, и скажите об этом отдельно.**

**Обход 2026-08-13: где ошибка ещё превращается в благополучный результат.**
После Битрикса проверены все места, где разбор ответа мог отдать пустоту вместо
отказа. Закрыто: `RussianTrackers` (незнакомая форма и отказ с кодом 200),
`SessionStore` (непрочитанный каталог архива). В ядре `?? []` не осталось.

Закрыто последним и `FirefliesPastCalls`: разбор списка встреч возвращал пустой
список и когда понять ответ не вышло, и когда встреч правда нет. Через импорт
это показывалось как «прошлых звонков нет» — при смене схемы у сервиса человек
решил бы, что импортировать нечего.

Сделано так, как и было записано: `parsedMeetingList` отдаёт `nil` на непонятый
ответ, импорт на `nil` поднимает ошибку, а прежняя форма осталась тонкой
обёрткой для мест, где различать нечего, — девять проверок не пришлось трогать.

**Отдельно — проверка, которой не будет (2026-08-13).** Веер источников для
подсказки собран группой задач: четыре подключённых трекера опрашиваются разом,
а не по очереди, иначе восьмисекундный срок каждого сложился бы в тридцать две
секунды посреди звонка. Это верно, но **закрепить проверкой не удалось**.

Две попытки, обе оказались пустыми:

1. Счёт `group.addTask` с порогом «хотя бы три» — удаление целого семейства
   источников компилируется и оставляет счётчик выше порога.
2. Поимённое упоминание семейств в файле — имена остаются в объявлениях и
   арифметике даже после удаления самого опроса.

Мутация показала обе. Замер длительности не годится тем более: на загруженной
машине последовательный веер укладывается в те же миллисекунды, и такая
проверка падала бы у случайного участника, ничего не сообщая о продукте.

Проверка удалена. Зелёная проверка, которая ничего не ловит, хуже отсутствующей:
она закрывает вопрос. Здесь вопрос оставлен открытым честно.

Итог обхода: пустота больше нигде не выдаётся за ответ. Проверки на обе стороны
у каждого случая: возврат к молчанию роняет их, и объявление настоящей пустоты
ошибкой — тоже. Вторая половина важна не меньше первой: без неё «ничего не
нашлось» исчезло бы там, где оно правда.

**У класса есть вторая половина, найденная 2026-08-13: не утверждение об
исходе, а указание, которое не сработает.** Проверять его надо иначе — вопрос
не «правда ли это?», а «сделает ли это тот, кто послушается?».

| что написано | что выйдет у того, кто послушается |
|---|---|
| «platform.moonshot.cn → API keys» рядом с полем ключа | ключ оттуда отвечает 401: запрос идёт на `api.moonshot.ai`, а зарегистрироваться на китайской половине обычно нельзя без местного телефона |
| README: «Сборка установщика: `MEETGPT_ARCH=arm64 ./notarize.sh && ./dmg.sh`» | собран один DMG из двух; второй остаётся вчерашним, и проверка сообщает о расхождении без объяснения причины |

Обе половины одного факта — консоль и адрес запроса, команда сборки и список
проверяемых образов — расходятся именно потому, что лежат порознь. Отсюда
второе правило: **держите половины рядом либо свяжите их проверкой**;
`ProviderConsoleMatchTests` и проверка README против `audit-dmg.sh` сделаны
ровно за этим.

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

### 5.1 Адрес сервера не зашивается — и это проверяется при сборке (2026-08-12)

Решения «сервера нет» недостаточно, пока в коде остаётся место, куда адрес может
вернуться. 2026-08-12 выяснилось, что он там и был: `build.sh` для
DIST-сборки честно оставлял `BACKEND_URL` пустым, а `Config.backendBaseURL`
на пустое значение подставлял продуктовый адрес по умолчанию — `api.cruxwing.ai`,
сервер другого продукта, который существует и отвечает. В установщике orakul
из-за этого оживали вход в аккаунт, счёт и обещание «моделей без своих ключей».

Отсюда правило, а не разовая правка:

1. `build.sh` в режиме DIST **печатает пустую строку** для `BACKEND_URL` и
   **останавливает сборку**, если значение непустое. Проверка перевёрнута
   относительно cruxwing: там запрещался адрес рабочей копии при обязательном
   боевом, здесь запрещён любой.
2. `Config.resolveBackendBaseURL` возвращает пустую строку и **ничего не
   подставляет**. Разбор вынесен из вычисляемого свойства отдельной функцией
   именно затем, чтобы его можно было проверить на всех входах, а не только на
   том, с которым собрана машина разработчика.
3. Всё, что требует сервера, закрыто признаком `backendBaseURL.isEmpty`:
   вход (четыре места), раздел «Аккаунт» в настройках, кнопка «Проверить в
   вебе», рельса кредитов. `NoBackendPromisesTests` проверяет **отрисовку**
   экрана, а не наличие строки в исходнике.

Почему так подробно: ошибка была не видна ни на одной проверке, которая читала
конфигурацию. Единственный способ её увидеть — смонтировать собранный DMG и
поискать адрес в бинарнике. Это и есть правило проверки для всего проекта:
проверять то, что уезжает пользователю, а не то, из чего оно собрано.

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

## 6.6 Словарь продукта задаёт демо-фильм, а не переводчик

Русские тексты orakul сверяются с `cruxwing-marketing/public/demo-film/scene.ru.js`
— это уже снятая русская дорожка, то есть голос продукта, который люди слышали.
Я успел написать свой вариант и разошёлся с ним на трёх словах:

| В фильме | Было у меня |
|---|---|
| **звонок** («Резюме звонка», «об этом звонке») | созвон |
| **слепые зоны** | спорные места |
| **владелец**, «без владельца» | «ответственный не назван» |

Каждое из моих слов — нормальный русский. Проблема не в них, а в том, что два
слова для одной вещи читаются как два разных продукта: пользователь, увидевший
в ролике «звонок», а в приложении «созвон», решает, что это разные штуки.

Проверяется тестом, который читает сам файл дорожки, а не копию из него:
разойтись молча теперь нельзя.

---

## 6.7 Падежи: центральное обещание не работало на целом разряде слов (проверено 2026-08-14)

Поиск сводит слово вопроса и слово речи к одной основе обрезкой окончаний.
Разряд существительных на «-ние» разъезжался целиком:

| Сказано на звонке | Спрошено | Основа речи | Основа вопроса |
|---|---|---|---|
| развёртывание | развёртыванием | `развёртыван` | `развёртывани` |
| обновление | обновления | `обновлен` | `обновлени` |
| решение | решению | `решен` | `решени` |

Именительный падеж терял «ие» целиком, косвенные — только последнюю букву.
Две разные основы у одного слова, то есть честное «в сохранённых звонках об
этом не говорили» о том, что говорили. Разряд — обычная лексика работы:
развёртывание, обновление, подключение, решение, тестирование, согласование,
требование. Прилагательные разъезжались так же на творительном: «годовой» →
`годов`, «годовым» → без изменений.

**Чем это ловится и чем не ловится.** Ни одна из 3006 проверок не падала.
Замер качества выдачи (`hit@1` на десяти вопросах реальной формы) показывал
10 из 10 до починки и 10 из 10 после — этого разряда в корпусе нет. Нашлось
запуском поиска на обычных русских словах, а не чтением кода и не замером.

**Что исправлено.** В список окончаний добавлено семейство на «и» («иями»,
«ием», «ией», «иям», «иях», «ия», «ию», «ии») и творительный прилагательных
(«ым», «им»); цикл обрезки начинается с четырёх знаков, иначе самое длинное
окончание не срабатывает никогда. Составные слова с дефисом теперь попадают в
указатель и целиком, и частями: «кластер» находит «Kubernetes-кластер».

**В приложении этого не было вовсе.** Разбор слова там сводился к «термин
словаря или слово как есть» — обрезки окончаний ни одной, при комментарии, что
шаг тот же, что в командной строке. Для русского вопроса совпадение множеств
слов и есть весь поиск: вторая половина — эмбеддинг системной модели macOS, а
она англоязычная. Теперь обе стороны зовут `RecallIndex.searchToken`.

**Чего обрезка окончаний не умеет и не будет.** Глагол через вид и
словообразование не сводится: «выкатываем» не найдётся по «выкатить»,
«переносим» по «перенос». Это не тот же изъян — суффиксная обрезка такого не
умеет в принципе, и настоящий стеммер (Snowball) эту пару тоже не сводит.
Написано на странице прямо, а не умолчано.

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

### 7.1 Windows: не «потом», а, возможно, вперёд macOS

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
звонках**, где он уже прозвучал и где у него есть автор и дата. Телеграм в
продукте появляется как источник контекста для собственной команды (свои чаты,
по явному подключению), а не как поисковый индекс по экосистеме.

---

## 8.1 Telegram: искать нечего, потому что нечем (проверено 2026-08-12)

§8 измерил фрагментацию и назвал поиск по рабочим чатам очевидным продолжением.
Проверка Bot API это закрывает: **бот не может ни читать, ни искать историю**.

- `getUpdates` отдаёт только новые события и хранит недоставленные **не дольше
  24 часов**;
- сообщений, отправленных до добавления бота, он не видит вовсе;
- метода «найти в переписке» в Bot API нет.

Значит, коннектора «поиск по вашему Telegram» не существует и написать его
нельзя. Единственный способ добраться до истории — MTProto с пользовательской
сессией, то есть попросить разработчика отдать приложению свой личный аккаунт
Telegram. Для продукта, который обещает, что всё остаётся на компьютере, это не
деталь реализации, а смена обещания.

Что технически возможно и не требует чужого аккаунта: бот, добавленный в чат,
видит всё **с этого момента**. Это не поиск по истории, а накопление своего
архива с даты подключения — и его уже можно индексировать локально тем же
`RecallIndex`. Честная формулировка для интерфейса: «ищет с того дня, когда вы
подключили», а не «ищет по вашим чатам».

Пока не сделано. Прежде чем делать, нужен ответ на вопрос из §10 — согласны ли
команды подключать рабочие чаты, — потому что это вопрос доверия, а не поиска.

---

## 9. Интеграция с GitHub (черновик архитектуры)

Метрика проекта — звёзды и установки, поэтому GitHub здесь не «ещё один
коннектор», а витрина. Две разные вещи, которые нельзя путать:

**9.1. Репозиторий как продукт.** Открытое ядро под Apache 2.0. Что решает
судьбу звезды: README, который запускается с первого раза, и понятная граница
между открытым и платным. Правило: всё, что обрабатывает речь пользователя, —
открыто; закрыто только то, что работает на нашей инфраструктуре.

**9.2. GitHub как источник контекста.** Связывает звонок с кодом: обсуждение
«давайте вынесем биллинг в отдельный сервис» и PR, который это делает, — одно
решение в двух местах.

| Что | Как | Почему так |
|---|---|---|
| Чтение issues/PR | GitHub REST + MCP-коннектор | Тот же слой, что и трекеры: коннектор, а не частный случай |
| Привязка решения к PR | по номеру и по названию ветки, произнесённым на звонке | Номер PR в речи — самый надёжный якорь; распознаётся как цифра, а не термин |
| Запись обратно | черновик комментария, отправляет человек | Правило продукта: сам он не отправляет ничего |
| Приватность | только по явному подключению репозитория | Код не уходит в модель без отдельного согласия |

**Задержка.** Тот же дедлайн, что у остальных коннекторов (8 с): один
подвисший источник стоит одного источника, а не всего ответа.

---

## 9.1 GitHub: почему токен, а не OAuth (проверено 2026-08-12)

Черновик выше предполагал подключение как у остальных: через MCP, в одно
нажатие. Живая проверка это опровергла.

`https://api.githubcopilot.com/mcp/` отвечает по спецификации: 401 и
`WWW-Authenticate` с адресом метаданных. Метаданные ресурса указывают на сервер
авторизации `https://github.com/login/oauth`. Его метаданные лежат по
нестандартному пути (`/.well-known/oauth-authorization-server/login/oauth`, а не
под issuer) и содержат:

```
authorization_endpoint: https://github.com/login/oauth/authorize
token_endpoint:         https://github.com/login/oauth/access_token
code_challenge_methods_supported: ["S256"]
registration_endpoint:  ОТСУТСТВУЕТ
```

PKCE есть, **динамической регистрации клиента нет**. Весь MCP-каталог в
приложении построен на ней: клиент регистрируется на лету, пользователь ничего
не заводит заранее. Для GitHub этот путь закрыт.

Второй вариант — заранее зарегистрированное OAuth-приложение с зашитым
секретом, как у HubSpot. Он тоже не работает: в готовые установщики секреты не
попадают намеренно (`build.sh`, `SECRET_VARS`), значит в скачанном orakul такой
строки просто не будет.

Остаётся личный токен — то, что GitHub поддерживает сам и что совпадает с
устройством остального продукта: ключи провайдеров и токены трекеров человек
вставляет руками. Реализовано в `GitHubConnector`, поиск по
`GET /search/issues`.

Две детали, найденные на живом API и закреплённые тестами: без `is:issue`
GitHub отвечает 422 части токенов, а версия API фиксируется заголовком
`X-GitHub-Api-Version` — иначе формат ответа вправе поменяться под нами.
Репозитории обязательны: без них поиск идёт по всему GitHub и приносит чужие
задачи, неотличимые от контекста команды.

---

## 10. What is still unknown

1. ~~Telegram dev-chat structure~~ — researched in §8. Remaining unknown is
   narrower: whether teams would connect their OWN work chats as a context
   source, which is a privacy question, not a search question.
2. ~~Willingness to pay, and where the tier boundary sits~~ — вопрос снят
   решением: тарифов нет, и это закреплено `NoTariffsTests`. Граница платного
   не ищется, потому что платного нет.
3. ~~Note-taking tool landscape~~ — проверено в §2.1. Осталось уже, чем было:
   нужен доступ к организации в Яндекс 360, чтобы вызвать метод поиска по вики и
   увидеть его ответ. Без этого коннектор не пишется.
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
[^qna-new]: Лента новых вопросов Хабр Q&A, первая страница, замер 2026-08-13: https://qna.habr.com/questions
[^habr-rules]: Обсуждение «Новые правила Хабра. Версия от 2026», комментарии, прочитано 2026-08-13: https://habr.com/ru/companies/habr/articles/1019036/comments/
[^megaplan]: Мегаплан, APIv3: авторизация и оговорка про документацию внутри аккаунта, проверено 2026-08-13: https://dev.megaplan.ru/apiv3/index.html
[^aspro]: Аспро.Cloud, страница про API без справочника методов, проверено 2026-08-13: https://aspro.cloud/api/
[^qna-noanswer]: Лента вопросов без ответа, первая страница, замер 2026-08-13: https://qna.habr.com/questions/without_answer
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

## 11. ВКС: почему коннектора к звонкам нет ни к одному из четырёх (проверено 2026-08-12)

§2 назвал четыре домашние платформы ВКС — Телемост, VK Teams, SaluteJazz
(бывш. SberJazz), TrueConf — и оставил коннекторы к ним в плане. Проверка по
документации каждой закрывает вопрос: **ни одна не даёт того, ради чего
коннектор нужен**.

Сначала — зачем он вообще нужен, потому что это не очевидно. На самом звонке
orakul не нужен ничей API: он берёт системный звук, и платформа для него
неотличима от плеера. Коннектор к ВКС дал бы ровно одно — **прошлые звонки, на
которых orakul не работал**: список встреч и их расшифровки. Это и проверялось.

| Платформа | Список встреч | Записи | Расшифровка | Что мешает |
|---|---|---|---|---|
| Яндекс Телемост | нет | нет | нет | В API три операции: `POST /v1/telemost-api/conferences`, `GET …/conferences/{id}`, изменение. Встречу можно создать и прочитать **по известному идентификатору** — перечислить нельзя. Записи приходят письмом ссылкой на Яндекс Диск, эндпоинта нет. Плюс нужен Яндекс 360 для бизнеса на домене организации |
| VK Teams | нет | нет | нет | Bot API — это отправка и приём сообщений, чаты, файлы, события. Звонков в нём нет вовсе. И та же стена, что у Telegram (§8.1): бот видит только адресованное ему |
| TrueConf | нет | только админка | нет | Записи лежат в разделе «Отчёты» веб-панели: воспроизвести, скачать, удалить — руками. Публично описанного HTTP-метода «дай список записей» нет. Сверх того нужен свой сервер и права администратора |
| SaluteJazz | комнаты | **есть** | **есть** | Единственная, у кого API покрывает и записи, и транскрипции. Упирается в авторизацию: нужен **ключ SDK организации**, а транспортный токен вендор требует генерировать **на бэкенде** приложения, и уже его менять на токен доступа через `POST /auth/login` |

**Вывод по SaluteJazz — отдельно, потому что он не про них, а про нас.** Их API
подошёл бы. Не подходит наша архитектура: у orakul нет бэкенда, на котором
положено генерировать транспортный токен, и появиться ему неоткуда — «сервера нет»
проверяется при сборке (§5.1). Зашить ключ SDK в клиент значит раздать ключ
организации всем, кто скачал приложение. Так что это не «не успели», а прямое
следствие решения, которое мы приняли раньше и не собираемся отменять.

**Что это меняет в продукте: ничего.** Запись звонка на любой из четырёх
платформ работает уже сегодня — системным захватом, без бота в комнате и без
разрешения вендора. Отсутствует только импорт чужого прошлого, и цена этого —
одна строка в «Чего ещё нет», а не сломанный сценарий.

**Что осталось бы сделать, если решение изменится.** Только SaluteJazz и только
с бэкендом: `POST /auth/login` за токеном доступа, затем список видеозаписей и
расшифровка встречи — тем же слоем `MCPGrounding`, что и трекеры, с тем же
кэшем и тем же тестом на живом сервисе (`LiveConnectorProbe`). Остальные три
не станут возможны от того, что мы передумаем.
