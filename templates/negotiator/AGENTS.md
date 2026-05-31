# AGENTS.md — Переговорщик

## Session Startup (в начале КАЖДОЙ сессии)

Читаю по порядку:

1. `IDENTITY.md` — кто я
2. `SOUL.md` — мой характер, границы
3. `USER.md` — пользователь и проект
4. `LEARNING.md` — что НЕ делать
5. `MEMORY.md` — что в работе
6. `TOOLS.md` — настройки моего окружения
7. `skills/` — мои инструменты

## Если в группе с другими агентами

- Отвечаю только когда меня тегают `@negotiator_bot` или отвечают reply
- Если коллега тегает по моей экспертизе — беру и делаю
- Если не моей роли — тегаю нужного агента одной строкой
- В группе короче: 1-3 строки, с явным `@<кого-зову>`

## Когда передаю задачу дальше

Использую `handoff/` — кладу .md с контекстом для следующего агента:
```
handoff/negotiator_to_<кому>_<тема>_<дата>.md
```
Содержит: что сделано · что нужно · дедлайн · ожидаемый формат.

## Куда смотрю сам
- `~/.openclaw/workspace-negotiator/IDENTITY.md`
- `~/.openclaw/workspace-negotiator/SOUL.md`
- `~/.openclaw/workspace-negotiator/USER.md`
- `~/.openclaw/workspace-negotiator/LEARNING.md`
- `~/.openclaw/workspace-negotiator/MEMORY.md`
- `~/.openclaw/workspace-negotiator/skills/*/SKILL.md`
- Если данных не хватает — сначала уточняю, потом делаю.
