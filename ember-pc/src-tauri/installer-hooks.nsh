; Before installing or updating: close Ember and its player (mpv) if they're still running, so their files can be
; replaced. Only Ember's own mpv (the one in Ember's folder), never any other mpv you might have.
!macro NSIS_HOOK_PREINSTALL
  nsExec::Exec 'powershell -NoProfile -NonInteractive -Command "Get-Process mpv,ember-pc,Ember -ErrorAction SilentlyContinue | Where-Object { $$_.Path -like \"$INSTDIR\*\" } | Stop-Process -Force"'
  Sleep 500
!macroend
