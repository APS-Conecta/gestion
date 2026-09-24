{
  "uniqueId": "page-aps-team-__TEAM_ID__",
  "title": "__TEAM_DISPLAY__",
  "language": "es",
  "layout": { "columns": 1, "rows": [
    { "columns": 1, "backgroundColor": "var(--color-primary-element)", "widgets": [
        { "type": "heading", "column": 1, "order": 1, "content": "Área de trabajo", "level": 3 },
        { "type": "heading", "column": 1, "order": 2, "content": "__TEAM_DISPLAY__", "level": 1 },
        { "type": "text",    "column": 1, "order": 3, "content": "Equipo de __SITE_NOMBRE_CORTO__ · visible para · __TEAM_ID__" } ] },
    { "columns": 1, "widgets": [
        { "type": "heading", "column": 1, "order": 1, "content": "Recursos del equipo", "level": 2 },
        { "type": "links", "column": 1, "order": 2, "title": "", "columns": 3, "items": [
          { "title": "Carpeta del equipo", "text": "Actas y plan de trabajo", "url": "/apps/files/?dir=/__TEAM_DIR__", "icon": "folder-outline", "target": "_self" },
          { "title": "Territorio",         "text": "Mapa del sector",         "url": "/apps/territorio/",               "icon": "map-outline",    "target": "_self" }
        ]} ] },
    { "columns": 1, "widgets": [
        { "type": "heading", "column": 1, "order": 1, "content": "Noticias del equipo", "level": 2 },
        { "type": "news", "column": 1, "order": 2, "title": "", "sourcePath": "equipos/__TEAM_ID__", "sourcePageId": "",
          "layout": "list", "columns": 1, "limit": 5, "sortBy": "modified", "sortOrder": "desc",
          "showImage": false, "showDate": true, "showExcerpt": true, "excerptLength": 120,
          "autoplayInterval": 0, "filters": [], "filterOperator": "AND" } ] }
  ], "sideColumns": [] }
}
