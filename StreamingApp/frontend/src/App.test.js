import { render, screen } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import { ProtectedRoute } from './components/ProtectedRoute';
import { AdminRoute } from './components/AdminRoute';
import { useAuth } from './contexts/AuthContext';

jest.mock('./contexts/AuthContext', () => ({
  useAuth: jest.fn(),
}));

function renderGuard(Guard) {
  return render(
    <MemoryRouter initialEntries={['/restricted']}>
      <Routes>
        <Route
          path="/restricted"
          element={
            <Guard>
              <div>Restricted content</div>
            </Guard>
          }
        />
        <Route path="/login" element={<div>Login destination</div>} />
        <Route path="/browse" element={<div>Browse destination</div>} />
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => {
  jest.resetAllMocks();
  useAuth.mockReturnValue({
    loading: false,
    user: null,
    isAuthenticated: () => false,
  });
});

test('protected route hides content while authentication is loading', () => {
  useAuth.mockReturnValue({
    loading: true,
    isAuthenticated: () => false,
  });

  renderGuard(ProtectedRoute);

  expect(screen.getByText('Loading...')).toBeInTheDocument();
  expect(screen.queryByText('Restricted content')).not.toBeInTheDocument();
});

test('protected route redirects unauthenticated users to login', () => {
  renderGuard(ProtectedRoute);

  expect(screen.getByText('Login destination')).toBeInTheDocument();
  expect(screen.queryByText('Restricted content')).not.toBeInTheDocument();
});

test('protected route allows authenticated users', () => {
  useAuth.mockReturnValue({
    loading: false,
    isAuthenticated: () => true,
  });

  renderGuard(ProtectedRoute);

  expect(screen.getByText('Restricted content')).toBeInTheDocument();
});

test('admin route hides content while authentication is loading', () => {
  useAuth.mockReturnValue({ loading: true, user: null });

  renderGuard(AdminRoute);

  expect(screen.getByText('Loading...')).toBeInTheDocument();
  expect(screen.queryByText('Restricted content')).not.toBeInTheDocument();
});

test('admin route redirects unauthenticated users to browse', () => {
  renderGuard(AdminRoute);

  expect(screen.getByText('Browse destination')).toBeInTheDocument();
  expect(screen.queryByText('Restricted content')).not.toBeInTheDocument();
});

test('admin route rejects authenticated non-admin users', () => {
  useAuth.mockReturnValue({
    loading: false,
    user: { role: 'user' },
  });

  renderGuard(AdminRoute);

  expect(screen.getByText('Browse destination')).toBeInTheDocument();
  expect(screen.queryByText('Restricted content')).not.toBeInTheDocument();
});

test('admin route allows administrators', () => {
  useAuth.mockReturnValue({
    loading: false,
    user: { role: 'admin' },
  });

  renderGuard(AdminRoute);

  expect(screen.getByText('Restricted content')).toBeInTheDocument();
});