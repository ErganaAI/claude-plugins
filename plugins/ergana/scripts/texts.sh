# Every line the plugin's shell scripts show, in English and in French: the one place their
# French is written (La3, John, 27 Nov 2026). Sourced, never run. The language is the Mac's LANG
# (DR-0029.D1): these lines come before or without a sign-in.
# say <key> [value…]: the line, each %s filled with the next value (values never read as a format).
say() {
  _say_key=$1
  shift
  case ${LANG:-} in fr*) _say_key="fr.$_say_key" ;; *) _say_key="en.$_say_key" ;; esac
  case $_say_key in
    en.later) _say_f='Later' ;;
    fr.later) _say_f='Plus tard' ;;
    en.committed) _say_f='committed .ergana file' ;;
    fr.committed) _say_f='fichier .ergana committé' ;;
    en.local) _say_f='local .ergana file' ;;
    fr.local) _say_f='fichier .ergana local' ;;
    en.workspace) _say_f='Ergana workspace: %s (%s)' ;;
    fr.workspace) _say_f='Espace Ergana : %s (%s)' ;;
    en.only) _say_f='Ergana workspace: %s (only workspace signed in on this machine)' ;;
    fr.only) _say_f='Espace Ergana : %s (seul espace connecté sur cette machine)' ;;
    en.sign_in_question) _say_f='Sign in to Ergana?' ;;
    fr.sign_in_question) _say_f='Se connecter à Ergana ?' ;;
    en.sign_in) _say_f='Sign in' ;;
    fr.sign_in) _say_f='Se connecter' ;;
    en.stop_checking) _say_f='Ergana › Checking the change before finishing.' ;;
    fr.stop_checking) _say_f='Ergana › Vérification du changement avant de terminer.' ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2059 # the format is one of the constants above
  printf "$_say_f" "$@"
}
