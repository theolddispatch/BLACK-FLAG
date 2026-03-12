# BLACK-FLAG

Scripts pour uploads automatiques vers [La Cale](https://la-cale.space), tracker privé français.

## Sommaire

### Versions BLACK-FLAG

- [BLACK-FLAG version exec](#black-flag-version-exec)
- [BLACK-FLAG version API](#black-flag-version-api)
- [BLACK-FLAG version web](#black-flag-version-web)
- [BLACK-FLAG version seedbox](#black-flag-version-seedbox)

### Perroquet

- [Perroquet version API](#perroquet-version-api)
- [Perroquet version web](#perroquet-version-web)

---

## BLACK-FLAG version exec

> À venir.

---

## BLACK-FLAG version API

> À venir.

---

## BLACK-FLAG version web

[`BLACK-FLAG version web/`](BLACK-FLAG%20version%20web/)

Script Bash autonome, à lancer manuellement ou via cron. Simple, sans dépendances.

---

## BLACK-FLAG version seedbox

[`BLACK-FLAG version seedbox/`](BLACK-FLAG%20version%20seedbox/)

Pour ceux qui gèrent une seedbox et veulent une solution qui tourne toute seule : pipeline complet de scan, nommage, upload et notifications, pensé pour s'intégrer à un environnement Radarr/Sonarr existant.

Peut tourner en natif sur la seedbox ou dans Docker — l'architecture modulaire (providers, uploaders, notifiers) permet d'adapter la configuration sans toucher au code. Gère les mises à jour, les erreurs et les doublons sans intervention manuelle.

> À réserver à ceux qui veulent une installation long terme, pas juste un script à lancer à la main.

Voir [`BLACK-FLAG version seedbox/README.md`](BLACK-FLAG%20version%20seedbox/README.md) pour la documentation complète.

```bash
# Cloner avec le submodule
git clone --recurse-submodules https://github.com/theolddispatch/BLACK-FLAG
```

---

## Perroquet version API

> À venir.

---

## Perroquet version web

> À venir.
