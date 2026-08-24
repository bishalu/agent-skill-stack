export function Button({
  isPrimary, isSecondary, isDanger, isGhost, isLarge, isSmall, isLoading, isDisabled, children,
}: {
  isPrimary?: boolean; isSecondary?: boolean; isDanger?: boolean; isGhost?: boolean;
  isLarge?: boolean; isSmall?: boolean; isLoading?: boolean; isDisabled?: boolean;
  children: React.ReactNode;
}) {
  const cls = [isPrimary && "primary", isSecondary && "secondary", isDanger && "danger",
    isGhost && "ghost", isLarge && "lg", isSmall && "sm"].filter(Boolean).join(" ");
  return <button className={cls} disabled={isDisabled}>{isLoading ? "..." : children}</button>;
}
