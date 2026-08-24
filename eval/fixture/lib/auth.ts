import jwt from "jsonwebtoken";

const SECRET = process.env.JWT_SECRET ?? "dev-secret";

export function verifySession(token: string) {
  try {
    return jwt.verify(token, SECRET) as { sub: string; role: string };
  } catch {
    return null;
  }
}

export function canEditWorkspace(user: { role: string }, _workspaceId: string) {
  return user.role === "admin" || user.role === "member";
}
