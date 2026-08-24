"use client";
import { useEffect, useState } from "react";

export function SettingsPage({ userId }: { userId: string }) {
  const [profile, setProfile] = useState<any>(null);
  const [prefs, setPrefs] = useState<any>(null);

  useEffect(() => {
    fetch(`/api/profile/${userId}`).then(r => r.json()).then(setProfile);
  }, [userId]);

  useEffect(() => {
    if (!profile) return;
    fetch(`/api/prefs/${profile.id}`).then(r => r.json()).then(setPrefs);
  }, [profile]);

  return <div>{prefs ? <pre>{JSON.stringify(prefs)}</pre> : "Loading"}</div>;
}
