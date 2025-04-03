import matplotlib.pyplot as plt
import numpy as np

# Sample data
x = np.linspace(0, 10, 100)
y1 = np.sin(x)  # First dataset
y2 = np.cos(x)  # Second dataset

fig, ax1 = plt.subplots()

# Plot first dataset on primary y-axis
ax1.plot(x, y1, 'b-', label='sin(x)')
ax1.set_xlabel('X axis')
ax1.set_ylabel('sin(x)', color='b')
ax1.tick_params(axis='y', labelcolor='b')

# Create a second y-axis
ax2 = ax1.twinx()
ax2.plot(x, y2, 'r-', label='cos(x)')
ax2.set_ylabel('cos(x)', color='r')
ax2.tick_params(axis='y', labelcolor='r')

# Show the plot
plt.title("Sin and Cos Functions with Different Y-Axes")
plt.show()
