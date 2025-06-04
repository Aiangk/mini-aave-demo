const Footer = () => {
  return (
    <footer
      style={{
        padding: '1rem',
        textAlign: 'center',
        borderTop: '1px solid #333',
      }}
    >
      <p>&copy; {new Date().getFullYear()} Mini Aave Demo</p>
    </footer>
  );
};
export default Footer;
