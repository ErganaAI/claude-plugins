"""Every line the plugin's Python scripts show, in English and in French: the one place their
French is written (La3, John, 27 Nov 2026). The language is the Mac's LANG (DR-0029.D1): these
lines come before or without a sign-in, when the server knows no person's language yet.

The scripts run under `python3 -I`, which keeps their own folder off sys.path: each loads this
file by its path (`load_texts` in each script), never by `import`.
"""

import os

MESSAGES = {
    'auth.access_was_denied_in': {
        "en": 'Access was denied in the browser.',
        "fr": "L'accès a été refusé dans le navigateur.",
    },
    'auth.allow': {
        "en": 'Allow',
        "fr": 'Autorisation',
    },
    'auth.back_to_claude_code': {
        "en": 'Back to Claude Code',
        "fr": 'Retour à Claude Code',
    },
    'auth.claude_code_is_connected': {
        "en": 'Claude Code is connected',
        "fr": 'Claude Code est connecté',
    },
    'auth.committed_ergana_file': {
        "en": 'committed .ergana file',
        "fr": 'fichier .ergana committé',
    },
    'auth.connected_token_expired_at': {
        "en": 'Connected, token expired at %s (renewed at the next connection).',
        "fr": 'Connecté, jeton échu depuis %s (renouvelé à la prochaine connexion).',
    },
    'auth.connected_token_valid_until': {
        "en": 'Connected, token valid until %s (renewed on its own after that).',
        "fr": "Connecté, jeton valable jusqu'à %s (renouvelé seul ensuite).",
    },
    'auth.copied': {
        "en": 'Copied',
        "fr": 'Copié',
    },
    'auth.copy': {
        "en": 'Copy',
        "fr": 'Copier',
    },
    'auth.ergana_s_tools_work': {
        "en": "Ergana's tools work in this session from their next call. If one still says the server is not connected: in /mcp, choose `plugin:ergana:ergana`, then `Reconnect`.",
        "fr": "Les outils d'Ergana fonctionnent dans cette session dès leur prochain appel. Si l'un d'eux dit encore que le serveur n'est pas connecté : dans /mcp, choisir `plugin:ergana:ergana`, puis `Reconnect`.",
    },
    'auth.html_lang': {
        "en": 'en',
        "fr": 'fr',
    },
    'auth.internal_error': {
        "en": 'internal error',
        "fr": 'erreur interne',
    },
    'auth.invalid_host': {
        "en": 'invalid host',
        "fr": 'hôte invalide',
    },
    'auth.invalid_origin': {
        "en": 'invalid origin',
        "fr": 'origine invalide',
    },
    'auth.invalid_server_response': {
        "en": 'invalid server response',
        "fr": 'réponse du serveur invalide',
    },
    'auth.invalid_workspace_3_to': {
        "en": 'invalid workspace (3 to 30 lowercase letters or digits)',
        "fr": 'espace invalide (3 à 30 lettres minuscules ou chiffres)',
    },
    'auth.keychain_unavailable': {
        "en": 'Keychain unavailable',
        "fr": 'Trousseau inaccessible',
    },
    'auth.local_ergana_file': {
        "en": 'local .ergana file',
        "fr": 'fichier .ergana local',
    },
    'auth.no_ergana_file_in': {
        "en": 'No .ergana file in this repository.',
        "fr": 'Aucun fichier .ergana dans ce dépôt.',
    },
    'auth.no_workspace_line_in': {
        "en": 'no workspace line in the .ergana file',
        "fr": 'fichier .ergana sans ligne workspace',
    },
    'auth.not_connected_ergana_login': {
        "en": 'Not connected: /ergana:login',
        "fr": 'Non connecté : /ergana:login',
    },
    'auth.not_in_a_git': {
        "en": 'not in a git repository',
        "fr": 'pas dans un dépôt git',
    },
    'auth.nothing_was_connected': {
        "en": 'Nothing was connected',
        "fr": "Rien n'a été connecté",
    },
    'auth.only_workspace_signed_in': {
        "en": 'only workspace signed in on this machine',
        "fr": 'seul espace connecté sur cette machine',
    },
    'auth.opening_the_browser_to': {
        "en": 'Opening the browser to sign in to Ergana. If nothing opens, open this link: %s',
        "fr": 'Ouverture du navigateur pour la connexion à Ergana. Sans ouverture, ouvrir ce lien : %s',
    },
    'auth.out_of_time': {
        "en": 'out of time',
        "fr": 'délai dépassé',
    },
    'auth.refused_by_the_server': {
        "en": 'refused by the server (HTTP %d)',
        "fr": 'refusé par le serveur (HTTP %d)',
    },
    'auth.renewal_already_in_progress': {
        "en": 'renewal already in progress',
        "fr": 'renouvellement déjà en cours',
    },
    'auth.repository_workspace_s_s': {
        "en": 'Repository workspace: %s (%s)',
        "fr": 'Espace du dépôt : %s (%s)',
    },
    'auth.revocation_not_confirmed_s': {
        "en": 'Revocation not confirmed: %s',
        "fr": 'Révocation non confirmée : %s',
    },
    'auth.server_unreachable': {
        "en": 'server unreachable',
        "fr": 'serveur injoignable',
    },
    'auth.sign_in': {
        "en": 'Sign in',
        "fr": 'Connexion',
    },
    'auth.sign_in_asked_for': {
        "en": 'Sign-in asked for the %s workspace; the account signed in belongs to the %s workspace.',
        "fr": "Connexion demandée à l'espace %s ; le compte connecté appartient à l'espace %s.",
    },
    'auth.sign_in_not_finished': {
        "en": 'sign-in not finished after 5 minutes',
        "fr": 'connexion non terminée après 5 minutes',
    },
    'auth.sign_in_not_offered': {
        "en": 'Sign-in not offered again in this repository.',
        "fr": 'Connexion non reproposée dans ce dépôt.',
    },
    'auth.sign_in_refused_in': {
        "en": 'sign-in refused in the browser',
        "fr": 'connexion refusée dans le navigateur',
    },
    'auth.signed_in_to_the': {
        "en": 'Signed in to the %s workspace.',
        "fr": "Connecté à l'espace %s.",
    },
    'auth.signed_out_of_the': {
        "en": 'Signed out of the %s workspace.',
        "fr": "Déconnecté de l'espace %s.",
    },
    'auth.steps': {
        "en": 'Steps',
        "fr": 'Étapes',
    },
    'auth.test_mode_never_production': {
        "en": 'test mode: never production, ERGANA_ORIGIN must name a test server',
        "fr": 'mode test : jamais la production, ERGANA_ORIGIN doit nommer un serveur de test',
    },
    'auth.the_s_workspace_is': {
        "en": 'The %s workspace is already connected.',
        "fr": "L'espace %s est déjà connecté.",
    },
    'auth.this_repository_is_linked': {
        "en": 'this repository is linked to the %s workspace by its .ergana file: sign-in to %s refused',
        "fr": "ce dépôt est lié à l'espace %s par son fichier .ergana : connexion à %s refusée",
    },
    'auth.this_repository_is_linked_2': {
        "en": 'This repository is linked to the %s workspace; the account signed in belongs to the %s workspace.',
        "fr": "Ce dépôt est lié à l'espace %s ; le compte connecté appartient à l'espace %s.",
    },
    'auth.this_repository_now_uses': {
        "en": 'This repository now uses <strong>%s</strong>. Go back to your terminal; you can close this tab.',
        "fr": 'Ce dépôt utilise désormais <strong>%s</strong>. Revenir au terminal ; cet onglet peut être fermé.',
    },
    'auth.to_try_again_run': {
        "en": 'To try again, run this in the repository:',
        "fr": 'Pour réessayer, lancer ceci dans le dépôt :',
    },
    'auth.token_not_stored_in': {
        "en": 'token not stored in the Keychain',
        "fr": 'jeton non rangé dans le Trousseau',
    },
    'auth.token_origin_differs': {
        "en": 'token origin differs',
        "fr": 'origine du jeton différente',
    },
    'auth.unreadable_ergana_file': {
        "en": 'unreadable .ergana file',
        "fr": 'fichier .ergana illisible',
    },
    'auth.workspace_needed_logout_workspace': {
        "en": 'workspace needed: logout --workspace <slug>',
        "fr": 'espace à indiquer : logout --workspace <espace>',
    },
    'auth.workspace_not_connected': {
        "en": 'workspace not connected',
        "fr": 'espace non connecté',
    },
    'auth.workspaces_connected_on_this': {
        "en": 'Workspaces connected on this machine: %s',
        "fr": 'Espaces connectés sur cette machine : %s',
    },
    'hook.redirected_request_not_followed': {
        "en": 'Ergana › redirected, request not followed',
        "fr": 'Ergana › réponse redirigée, requête non suivie',
    },
    'hook.server_too_slow': {
        "en": 'Ergana › server too slow',
        "fr": 'Ergana › serveur trop lent',
    },
    'hook.server_unreachable': {
        "en": 'Ergana › server unreachable',
        "fr": 'Ergana › serveur injoignable',
    },
    'hook.sign_in_refused_ergana': {
        "en": 'Ergana › sign-in refused: /ergana:login',
        "fr": 'Ergana › connexion refusée : /ergana:login',
    },
    'hook.test_mode_never_production': {
        "en": 'Ergana › test mode: never production, ERGANA_ORIGIN must name a test server',
        "fr": 'Ergana › mode test : jamais la production, ERGANA_ORIGIN doit nommer un serveur de test',
    },
    'hook.unreadable_answer': {
        "en": 'Ergana › unreadable answer',
        "fr": 'Ergana › réponse illisible',
    },
}


def say(key):
    """The line `key` in the Mac's language: French when LANG starts with fr, else English."""
    return MESSAGES[key]["fr" if os.environ.get("LANG", "").startswith("fr") else "en"]
